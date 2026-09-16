import Foundation

/// 把各平台的价格显示串解析成数字。
///
/// **为什么不能只留数字**
/// -------------------
/// 各平台的写法不是一套。实测数据里 Holland2Stay 写 `€1,067`（逗号分位），
/// OurDomain 写 `€ 1.152`（**点**分位）。只留数字的话 `€1.067,50` 会变成
/// 106750——差一百倍。荷兰租金基本都是整数所以线上没炸过，但这是运气不是设计。
///
/// **为什么在包里而不是各端各写一份**
/// -------------------------------
/// 地图的 `maxRentText` 筛选和 Mac 地图的价格色带都要它。两份实现只要有一点
/// 不一致，就会出现"通过了 ≤€900 的筛选、却被涂成 over €1,200"这种自相矛盾。
public nonisolated enum PriceText {

    /// 解析不出来返回 `nil`——**不返回 0**。0 会悄悄落进"最便宜"那一档，
    /// 而"不知道多少钱"和"免费"是两回事。
    /// 紧凑显示：`€1068`、`€452`。
    ///
    /// 给一行放不下几个字的地方用（日历格子里的条目卡、地图标记）。走
    /// ``parse(_:)`` 归一化之后重新格式化，而不是把后端那串原样截断——
    /// 各平台的写法差得很远（`"€ 1.067,50 p/m"` / `"1067.5"` / `"€1,067.50"`），
    /// 原样显示会让同一列里出现三种格式。
    ///
    /// **不带千位分隔符**，虽然设计稿写的是 `€1,180`。四位数的租金不靠分隔符断读，
    /// 而少一个符号就少一次「这个点/逗号是分位还是小数」的判断——各平台原样串
    /// 之所以会被读错，根子就在这个判断上。
    ///
    /// 这句话以前是**假的**：注释写着"app 里其它地方一直是不带的"，而 iOS 列表的
    /// `ListingRow` 自己揣着一个加逗号的 formatter，显示 `€1,067`。两端不一致了
    /// 很久，只是没人把两块屏幕并排看过。现在两端所有显示价格的地方都走这里，
    /// 那个 formatter 已经删掉，这句话才真的成立。
    ///
    /// 一律不带小数：租金列表里 `.50` 那两位不影响任何判断，却要吃掉三个字符。
    /// 解析不出来时返回 nil，**不返回 "€0"**——那是在编一个数字。
    public static func compact(_ raw: String?) -> String? {
        guard let value = parse(raw) else { return nil }
        return format(value)
    }

    /// ``compact(_:)`` 的后半段：已经是数字了，只负责格式化成 `€1125`。
    ///
    /// 单独暴露出来，是给**后端已经解析好**的那条路用（`Listing.price_value`）。
    /// 那种情况下再去解析一遍 `price_raw` 是多此一举，而且多一次出错的机会。
    public static func format(_ value: Double) -> String? {
        formatter.string(from: NSNumber(value: value.rounded()))
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 0
        f.positivePrefix = "€"
        return f
    }()

    public static func parse(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        // 只留数字和两种分隔符，货币符号 / 空格 / "per month" 一律扔掉。
        let s = raw.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard !s.isEmpty else { return nil }

        // 先判定**哪一个字符**是小数点（可能一个都不是）。
        let lastDot = s.lastIndex(of: ".")
        let lastComma = s.lastIndex(of: ",")
        var decimalIndex: String.Index?
        if let d = lastDot, let c = lastComma {
            // 两种都有 → 靠后的那个是小数点。
            // `1.234,56`（欧陆）和 `1,234.56`（英美）都能对。
            decimalIndex = d > c ? d : c
        } else if let only = lastDot ?? lastComma {
            // 只有一种：后面**正好跟三位数字**就是分位符（`1.152` / `1,067`），
            // 否则当小数点（`12,5`）。
            let after = s.distance(from: s.index(after: only), to: s.endIndex)
            decimalIndex = after == 3 ? nil : only
        }

        // 重建：数字照抄，只有被判定为小数点的那一个位置写 "."，其余分隔符丢掉。
        // 按**下标**而不是按字符判断——`1.234.567` 里只有最后那个点算数。
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isNumber {
                out.append(s[i])
            } else if i == decimalIndex {
                out.append(".")
            }
            i = s.index(after: i)
        }
        return Double(out)
    }
}
