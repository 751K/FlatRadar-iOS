import Foundation

/// `GET /api/v1/listings?sort=` 的排序规则，**照后端逐条搬过来**。
///
/// 出处（holland2stay-monitor，钉在 `tools/server-sort/make_fixture.py` 的 `BACKEND_SHA`）：
/// - `app/services/listing_service.py`：`sort_listing_rows` / `_sort_value` / `status_rank`
/// - `models.py`：`parse_float` / `is_sentinel_available_from` / `parse_features_list`
/// - `config.py`：`energy_rank`
/// - `mstorage/_derived.py`：面积、能效两个派生列
///
/// 为什么要有它
/// -----------
/// Mac 把整个结果集都拉进了内存（`loadAllPages`），点列头却还是从第一页重新请求，
/// 两千条每页五百就是四个请求，来回切几次排序就是几倍的请求和解码（代码审查）。
/// 全量在手时，本地重排就够了——**前提是顺序和服务端一模一样**：否则之后一刷新，
/// 行会整片跳动，而且本地"最便宜的"和服务端"最便宜的"不是同一套房。
///
/// 所以这里不是"一个看起来合理的排序"，而是后端那几行 Python 的逐条翻译。
/// `ServerListingOrderTests` 拿后端**原始代码**跑出来的顺序逐条对照。
///
/// 规则（后端原话的要点）
/// --------------------
/// 1. 先按 `id` 升序，再按键稳定排序（降序时并列的仍是 `id` 升序），
///    最后把"未知"的一律沉底——**无论升降序**。
/// 2. 字符串比较是 Python 的**码位序**，不是 Swift `String <` 的规范化比较。
/// 3. 价格：`price_value`（后端 `parse_float(price_raw)`，接口直接给）。
/// 4. 面积：`parse_float(feature_map["area"])`，≤ 0 算未知。
/// 5. 能效：`energy_label` 在 `A+++ … F` 里的下标，越小越好；不在白名单里算未知。
/// 6. 状态：业务序（可订 0、抽签 1、预留 2、已租 3、其它 9），**永不算未知**。
/// 7. 入住日：去空格后的原文；空的、或年份 ≥ 2050（后端的"不知道"哨兵）算未知。
/// 8. 城市：去空格 + 小写；来源 / 首见 / 末见：去空格；空串算未知。
///
/// 已知的一处对不上：后端序列化时把**空的** `source` 写成 `"holland2stay"`，排序却
/// 按空串（未知）算。客户端看不到原值，这种行在"按来源排"时位置会不同。线上的
/// 抓取器总会写 source，目前不存在这样的行。
public nonisolated enum ServerListingOrder {

    public static func sorted(_ listings: [Listing], by sort: ListingSort) -> [Listing] {
        // 排序键先算好：比较器里现算的话，两千条要解析两万多次。
        let keyed = listings.map { (listing: $0, key: sortKey($0, sort.key), id: Array($0.id.unicodeScalars)) }
        return keyed.sorted { a, b in
            // 未知的一律沉底，升降序都一样。
            if a.key.unknown != b.key.unknown { return !a.key.unknown }
            switch compare(a.key.value, b.key.value) {
            case .orderedAscending:  return sort.ascending
            case .orderedDescending: return !sort.ascending
            case .orderedSame:       return precedes(a.id, b.id)   // id 兜底，升降序都是升
            }
        }
        .map(\.listing)
    }

    // MARK: - 排序键

    enum Value {
        case number(Double)
        case text([Unicode.Scalar])
    }

    struct Key {
        let unknown: Bool
        let value: Value
    }

    static func sortKey(_ l: Listing, _ key: ListingSortKey) -> Key {
        switch key {
        case .price:
            let v = l.priceValue ?? parseFloat(l.priceRaw)
            return Key(unknown: v == nil, value: .number(v ?? 0))
        case .area:
            var v = parseFloat(l.featureMap["area"])
            if let a = v, a <= 0 { v = nil }       // 0 平米是脏数据，不是真值
            return Key(unknown: v == nil, value: .number(v ?? 0))
        case .energy:
            let v = energyRank(l.featureMap["energy_label"])
            return Key(unknown: v == nil, value: .number(Double(v ?? 0)))
        case .status:
            return Key(unknown: false, value: .number(Double(statusRank(l.status))))
        case .availableFrom:
            let raw = strip(l.availableFrom)
            let unknown = raw.isEmpty || isSentinelAvailableFrom(raw)
            return Key(unknown: unknown, value: .text(unknown ? [] : Array(raw.unicodeScalars)))
        case .city:
            return text(strip(l.city).lowercased())
        case .source:
            return text(strip(l.source))
        case .firstSeen:
            return text(strip(l.firstSeen))
        case .lastSeen:
            return text(strip(l.lastSeen))
        }
    }

    private static func text(_ s: String) -> Key {
        Key(unknown: s.isEmpty, value: .text(Array(s.unicodeScalars)))
    }

    private static func strip(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compare(_ a: Value, _ b: Value) -> ComparisonResult {
        switch (a, b) {
        case let (.number(x), .number(y)):
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case let (.text(x), .text(y)):
            if x == y { return .orderedSame }
            return precedes(x, y) ? .orderedAscending : .orderedDescending
        default:
            return .orderedSame     // 同一个键下类型总是一致的，走不到这里
        }
    }

    /// Python 的字符串比较：逐个码位比。
    private static func precedes(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Bool {
        a.lexicographicallyPrecedes(b) { $0.value < $1.value }
    }

    // MARK: - 后端函数的逐条翻译

    /// `models.parse_float`：取第一段 `\d[\d,.]*`，按最后一个分隔符判断小数点。
    ///
    /// 和后端的两处差别，都在后端会直接抛异常的输入上（那种数据进不了接口）：
    /// 非 ASCII 数字、`"1.2.3"` 这类解析不了的，这里返回 nil。
    static func parseFloat(_ text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        let scalars = Array(text.unicodeScalars)
        func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }
        guard let start = scalars.firstIndex(where: isDigit) else { return nil }
        var end = start + 1
        while end < scalars.count, isDigit(scalars[end]) || scalars[end] == "," || scalars[end] == "." {
            end += 1
        }
        var token = String(String.UnicodeScalarView(scalars[start..<end]))
        let hasComma = token.contains(","), hasDot = token.contains(".")
        if hasComma && hasDot {
            // 最后出现的那个是小数点，另一个是千分位。
            if token.lastIndex(of: ".")! > token.lastIndex(of: ",")! {
                token = token.replacingOccurrences(of: ",", with: "")
            } else {
                token = token.replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            }
        } else if hasComma {
            token = isThousands(token, separator: ",")
                ? token.replacingOccurrences(of: ",", with: "")
                : token.replacingOccurrences(of: ",", with: ".")
        } else if hasDot, isThousands(token, separator: ".") {
            token = token.replacingOccurrences(of: ".", with: "")
        }
        return Double(token)
    }

    /// `re.fullmatch(r"\d{1,3}(?:<sep>\d{3})+", token)`
    private static func isThousands(_ token: String, separator: Character) -> Bool {
        let parts = token.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count >= 2, (1...3).contains(parts[0].count) else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
            && parts.dropFirst().allSatisfy { $0.count == 3 }
    }

    /// `config.energy_rank`：白名单精确匹配（大小写不敏感），越小越好。
    static let energyLabels = ["A+++", "A++", "A+", "A", "B", "C", "D", "E", "F"]

    static func energyRank(_ label: String?) -> Int? {
        energyLabels.firstIndex(of: strip(label).uppercased())
    }

    /// `listing_service.status_rank`。**判断顺序不能改**：lottery 先判。
    static func statusRank(_ status: String) -> Int {
        let s = strip(status).lowercased().replacingOccurrences(of: "_", with: " ")
        if s.contains("lottery") { return 1 }
        if s.contains("available to book") || s == "book" { return 0 }
        if s.contains("reserved") { return 2 }
        if s.contains("occupied") || s.contains("rented") || s.contains("not available") { return 3 }
        return 9
    }

    /// `models.is_sentinel_available_from`：年份 ≥ 2050 是"不知道"，不是日期。
    static func isSentinelAvailableFrom(_ value: String) -> Bool {
        let v = strip(value)
        let head = v.prefix(4)
        guard !v.isEmpty, head.allSatisfy({ $0.isASCII && $0.isNumber }), let year = Int(head)
        else { return false }
        return year >= 2050
    }
}
