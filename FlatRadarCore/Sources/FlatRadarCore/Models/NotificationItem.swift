import Foundation

/// `Equatable` 是给 Mac 通知屏的缓存用的：整批通知当键，内容没变就不重新解析
/// （见 FlatRadarMac 的 `Memo`）。按全部字段比，已读状态变了也算变。
public nonisolated struct NotificationItem: Decodable, Identifiable, Equatable, Sendable {
    public let id: Int
    let createdAt: String
    public let type: String
    public let title: String
    public let body: String
    public let url: String
    public let listingID: String
    /// `var` 只为 ``markedRead()``：标已读只该改这一个字段，见那里的说明。
    private(set) var read: Int
    /// Decode 时计算一次，后续访问 O(1)，避免每次 filter 都重复做 lowercased + contains。
    public let kind: Kind

    /// 去掉前缀/emoji/[标签] 后的纯标题——**预计算**（含一次正则）。
    /// 之前是 computed property，每次行渲染都现跑 `.regularExpression`（最贵的
    /// 单行操作），列表滚动/切类型时 ×N 行触发 N 次正则编译+执行 → 卡。
    /// 移到 decode 时算一次存起来，渲染只读字段。
    public let listingTitleHint: String

    /// `createdAt` 的解析结果——**预计算**一次。createdDate / ageText / dayBucket
    /// 之前每次行渲染都重解析日期；这里 decode 时解一次，渲染只读。
    let parsedDate: Date?

    public enum CodingKeys: String, CodingKey {
        case id, type, title, body, url, read
        case createdAt = "created_at"
        case listingID = "listing_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        type = try c.decode(String.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        listingID = try c.decodeIfPresent(String.self, forKey: .listingID) ?? ""
        read = try c.decodeIfPresent(Int.self, forKey: .read) ?? 0
        kind = Self.classifyKind(type: type, title: title, body: body)
        listingTitleHint = Self.computeListingTitleHint(title)
        parsedDate = Self.parseCreatedDate(createdAt)
    }

    /// 用于 markedRead() / 测试构造的手动 init
    init(id: Int, createdAt: String, type: String, title: String,
         body: String, url: String, listingID: String, read: Int) {
        self.id = id
        self.createdAt = createdAt
        self.type = type
        self.title = title
        self.body = body
        self.url = url
        self.listingID = listingID
        self.read = read
        self.kind = Self.classifyKind(type: type, title: title, body: body)
        self.listingTitleHint = Self.computeListingTitleHint(title)
        self.parsedDate = Self.parseCreatedDate(createdAt)
    }

    public var isRead: Bool { read != 0 }

    /// 同一条通知，只把已读位翻过来。
    ///
    /// **复制，不重建。** 原先这里走上面那个手动 init：分类、标题正则、日期解析全部
    /// 重跑一遍——而标已读根本不改变它们。「全部已读」一次就是整批重建，两千条时
    /// 标准 ISO 日期约 40ms、无时区格式（要逐个试备用解析器）约 135ms，全在主线程
    /// 上（代码审查）。
    func markedRead() -> NotificationItem {
        var copy = self
        copy.read = 1
        return copy
    }

    /// 纯函数：title → 去前缀标题。decode 时调一次，结果存进 ``listingTitleHint``。
    static func computeListingTitleHint(_ title: String) -> String {
        let separators = ["：", ":"]
        var value = title
        for sep in separators {
            if let range = value.range(of: sep) {
                value = String(value[range.upperBound...])
                break
            }
        }
        value = value.replacingOccurrences(
            of: #"^\s*(?:[^\p{L}\p{N}\[]+\s*)?(?:\[[^\]]+\]\s*)?"#,
            with: "",
            options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public extension NotificationItem {
    /// 通知的语义分类——决定 V2 卡片的颜色 / 图标 / 事件标签。
    ///
    /// - `book`    新房源（available to book）
    /// - `lottery` 新房源（available in lottery）
    /// - `status`  状态变化（reserved ↔ book ↔ lottery）
    /// - `alert`   服务端异常（403 / blocked / 抓取失败）
    /// - `test`    手动触发的测试推送（SSE TEST / Test push）
    /// - `system`  兜底——其它系统消息
    nonisolated enum Kind: Sendable {
        case book, lottery, status, alert, test, system
    }

    /// 后端的 `type` 字段写法不统一：new_listing / status_change / error / blocked /
    /// test / sse_test / info / system 都见过。再叠加 title/body 的关键字做兜底
    /// （比如"available in lottery"出现在 body 里就归为 lottery）。
    ///
    /// 这是静态方法，decode 时由 ``init(from:)`` 调用一次存入 ``kind`` 存储属性，
    /// 之后所有 filter / group 操作都是 O(1) struct field read。
    ///
    /// `nonisolated`：`init(from:)` 是 Decodable 的 nonisolated 见证，从那里
    /// 调它。类型声明上的 `nonisolated` 盖不到 extension，得在这里单标。
    nonisolated static func classifyKind(type: String, title: String, body: String) -> Kind {
        let t = type.lowercased().replacingOccurrences(of: "_", with: " ")
        let blob = "\(title) \(body)".lowercased()

        // 显式 test（含中文测试推送）
        if t.contains("test") || blob.contains("sse test") || blob.contains("test push")
            || blob.contains("🧪") || blob.contains("测试推送") || blob.contains("推送链路") {
            return .test
        }
        // 服务端异常类
        if t.contains("error") || t.contains("block") || t.contains("alert")
            || t.contains("403") || t.contains("fail") {
            return .alert
        }
        // 状态变化
        // ⚠️ 顺序要紧：**先认 `type`，正文启发式只作最后的兜底**。
        //
        // 之前是 `t.contains("status") || t.contains("change") || blob.contains("→")`
        // 排在新房源分支前面。而 `notifier.py` 拼的新房源 body 是
        // `f"{status} · {price}/mo · → {move_in}"`——**里面那个 `→` 是入住日**，
        // 不是状态迁移。结果每一条 `new_listing` 都被判成 `.status`：
        // Mac 通知屏实测 17 条里 Status 17 / New 0，iOS 的筛选标签同样中招。
        if t.contains("new listing") || t.contains("booking") {
            return blob.contains("lottery") || blob.contains("抽签") ? .lottery : .book
        }
        if t.contains("status") || t.contains("change") {
            return .status
        }
        // 到这里说明 `type` 认不出，才轮到正文猜。
        if blob.contains("→") { return .status }
        if t.contains("listing") {
            return blob.contains("lottery") || blob.contains("抽签") ? .lottery : .book
        }
        return .system
    }

    // MARK: - 共享日期格式化器（static，避免每次访问重新分配）
    //
    // DateFormatter 的创建是已知最贵的 Foundation 操作之一（~100–200μs）。
    // createdDate 是计算属性，ageText / dayBucket 都会调它——之前每次访问都
    // 现 new 一批出来，列表滚动时每行每帧重复分配，开销显著。
    //
    // 改成 static let 一次性建好复用。DateFormatter 自 iOS 7 起对并发
    // "解析/格式化"是线程安全的（只读不改 options），所以全局共享安全。
    //
    // ISO 那两个拆成含 / 不含小数秒两份。以前这么拆是为了避免运行时改
    // `formatOptions`（那会破坏共享）；换成 `Date.ISO8601FormatStyle` 之后
    // 它本来就是不可变值类型，拆开纯粹是因为后端两种形态都发过。
    //
    // `nonisolated`：SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor 会把这些
    // static let 也推断成主 actor，而 parseCreatedDate 是 nonisolated
    // （它服务于 Decodable 的 init(from:)），跨不过去。

    nonisolated fileprivate static let amsterdamTZ: TimeZone =
        TimeZone(identifier: "Europe/Amsterdam") ?? .current

    /// ISO8601 两种形态：带小数秒和不带。后端两种都发过，所以两个都留着。
    ///
    /// 用 `Date.ISO8601FormatStyle` 而不是 `ISO8601DateFormatter`：
    ///
    /// - 它是 **`Sendable` 的值类型**，`nonisolated` 就够了，不必再挂
    ///   `(unsafe)` 去关掉并发检查。工程里最后几个 `nonisolated(unsafe)` 全是
    ///   为这个旧类留的。
    /// - `includingFractionalSeconds` 之外的默认值正好等于
    ///   `.withInternetDateTime`：dateSeparator `-`、dateTimeSeparator `T`、
    ///   timeSeparator `:`、timeZoneSeparator 省略、时区 UTC。所以这是**行为
    ///   等价**的替换，不是"差不多"。
    nonisolated private static let isoFractional =
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    nonisolated private static let isoPlain =
        Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    /// 多格式兜底解析器（Europe/Amsterdam，en_US_POSIX 固定 locale）。
    nonisolated private static let fallbackParsers: [DateFormatter] = {
        ["yyyy-MM-dd HH:mm:ss",
         "yyyy-MM-dd HH:mm",
         "yyyy-MM-dd'T'HH:mm:ss.SSS",
         "yyyy-MM-dd'T'HH:mm:ss"].map { fmt in
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = amsterdamTZ
            f.dateFormat = fmt
            return f
        }
    }()

    /// "超过一周"时显示的具体日期（"MMM d"，跟随系统 locale）。
    nonisolated private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = .autoupdatingCurrent
        f.timeZone = amsterdamTZ
        f.dateFormat = "MMM d"
        return f
    }()

    /// 纯函数：解析 `createdAt` → Date。decode 时调一次，结果存进 ``parsedDate``。
    /// 用 Europe/Amsterdam 算相对年龄，避免本地时区漂移。
    /// `nonisolated` 的理由同 ``classifyKind(type:title:body:)``。
    nonisolated static func parseCreatedDate(_ createdAt: String) -> Date? {
        let raw = createdAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if let d = try? isoFractional.parse(raw) { return d }
        if let d = try? isoPlain.parse(raw) { return d }
        for f in fallbackParsers {
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }

    /// 兼容旧调用点：直接返回预计算好的 ``parsedDate``（零解析）。
    /// `public` 是为 Mac 端的通知流开的：它要按天分组、按 2 小时分桶画柱状图，
    /// 两件事都得拿到解析好的日期。`parsedDate` 本身留在包内（decode 时算一次）。
    public nonisolated var createdDate: Date? { parsedDate }

    /// 相对年龄串：`now` / `38m` / `5h` / `2d`。
    ///
    /// 算法搬进了 ``ServerTime/compactAge(since:now:)``：小组件的 NEWEST 三行
    /// 要贴同样的一小格，而它得按"条目打算什么时候显示"来算（WidgetKit 提前
    /// 渲染），这里的 `Date()` 那一版给不了。两处共用一份，写法不会漂。
    nonisolated var ageText: String {
        guard let d = createdDate else { return "" }
        return ServerTime.compactAge(since: d, now: Date())
    }

    /// "Today" / "Yesterday" / "Earlier" 三段——给 NotificationsView 做 Section 分组。
    nonisolated enum DayBucket: String, CaseIterable {
        case today, yesterday, earlier
    }

    nonisolated private static let amsterdamCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = amsterdamTZ
        return cal
    }()

    nonisolated var dayBucket: DayBucket {
        guard let d = createdDate else { return .earlier }
        let cal = Self.amsterdamCalendar
        if cal.isDateInToday(d) { return .today }
        if cal.isDateInYesterday(d) { return .yesterday }
        return .earlier
    }
}
