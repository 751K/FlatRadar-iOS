import Foundation

/// 「当前状态」那几句话，全 App 唯一一份。
///
/// 同一件事现在有三个出口：Mac 列表页顶上的统计带（``StatsStrip``）、菜单栏那一格
/// （``MenuBarStatusView``）和桌面小组件（``StatusWidget``），docs/NEXT.md 里 iOS 的
/// 主屏小组件是第四个。docs/MACOS.md 对它们只有一句要求：
///
/// > 最后一条和 iOS 那个"状态型小组件"是同一个东西，先做哪个都行，
/// > 但**文案和口径要一致**。
///
/// 一句写在文档里的要求，靠的是每个动这段代码的人记得；写成下面这些函数，
/// 靠的是编译器。差别在「改一处忘了另一处」发生的时候：前者两端从此说两种话，
/// 而且不会有任何东西报错。
///
/// **这不是假想，收拢的时候当场抓到两处**：
///
/// | | 匹配数那一格的标题（没套筛选时） |
/// |---|---|
/// | `StatsStrip` | `Showing` |
/// | `MenuBarStatusView` | `Listings` |
/// | 它自己的注释 | 写着「没套就是 `Showing`」，而它正下方的代码返回 `Listings` |
///
/// 同一台机器上的两个位置，同一个数，两个名字。统一成 `Listings`——它说的是
/// **那是什么**，而 `Showing` 说的是"界面正在干什么"，后者在菜单栏和小组件里
/// 根本讲不通（那两处不"showing"任何列表）。
public nonisolated enum StatusWording {

    // 全部查 Core 自己的字符串表（`bundle: .module`）。原先是裸的英文常量，
    // Mac 统计带、菜单栏和小组件在任何语言下都显示英文——而它们正是「一处定义、
    // 多处共用」的那批，漏一处等于漏好几屏。常量因此从 `let` 改成计算属性：
    // 语言是运行时的事，`let` 在第一次读的时候就焊死了。

    // MARK: - 匹配数

    /// 套了个人筛选叫 `Matching filters`，没套叫 `Listings`。
    ///
    /// 两处说法不一致的话，用户会以为那是两个数。
    public static func countLabel(isFiltered: Bool) -> String {
        isFiltered ? String(localized: "Matching filters", bundle: .module)
                   : String(localized: "Listings", bundle: .module)
    }

    /// 拿不到就是 `—`，**不是 `0`**。
    ///
    /// 0 是「一套都没匹配上」，那是个事实；拿不到不是事实，是没拿到。
    public static func countText(_ count: Int?) -> String {
        count.map(String.init) ?? "—"
    }

    // MARK: - 统计带上那四个标题

    /// 锚点。设计稿 t3 的原话：「打开 app 第一眼要看的是"现在有什么新的"」。
    public static var newToday: String { String(localized: "New today", bundle: .module) }
    /// 全库，不是这个账号的。标签把口径写在脸上——实测库里 828 条而账号只匹配 80 条。
    public static var totalListings: String { String(localized: "Total listings", bundle: .module) }
    public static var statusChanges: String { String(localized: "Status changes", bundle: .module) }
    /// `new_7d`。iOS 大号第二格。
    public static var newThisWeek: String { String(localized: "New this week", bundle: .module) }
    public static var unread: String { String(localized: "Unread", bundle: .module) }

    /// 4b 大号那个红胶囊里跟在数字后面的词：`7 unread`。跟在数字后面，所以小写。
    public static var unreadLower: String { String(localized: "unread", bundle: .module) }

    // MARK: - 锁屏挂件（设计稿 4c）

    /// 圆形挂件里压在数字底下那三个字母。锁屏那一格只有 62pt 见方，
    /// `NEW TODAY` 放不下，稿子上写的就是 `NEW`。
    public static var newShort: String { String(localized: "new", bundle: .module) }
    /// 矩形挂件第一行里跟在数字后面的词：`31 new · 7 unread`。
    public static var newLower: String { String(localized: "new", bundle: .module) }

    /// 内联挂件那一行：`FlatRadar · 31 new today`。
    ///
    /// 拿不到数时不写 `FlatRadar · — new today`——那读起来像个坏掉的模板。
    /// 退回只说名字，让系统那一行安静地待着。
    public static func inlineSummary(_ newToday: Int?) -> String {
        guard let newToday else { return "FlatRadar" }
        return String(localized: "FlatRadar · \(newToday) new today", bundle: .module)
    }

    // MARK: - 小组件那几段的标题
    //
    // 设计稿里它们是全大写的等宽小标签，但**这里存的是正常大小写**——
    // 大写是排版（`.textCase(.uppercase)`），不是文案。存大写的话，同一句话在
    // 统计带（`New today`）和小组件（`NEW TODAY`）就成了两个字符串常量。

    /// NEWEST 那三行的段标题。
    public static var newest: String { String(localized: "Newest", bundle: .module) }
    /// 大号那三格里的第一格。就是全库房源数，换了个更口语的说法——
    /// 那一格窄，`Total listings` 放不下。
    public static var liveNow: String { String(localized: "Live now", bundle: .module) }

    /// `831 live`。小号底下那行的前半句。
    public static func liveCount(_ n: Int) -> String { String(localized: "\(n) live", bundle: .module) }

    /// `84 matching`。汇总行里的一段。
    ///
    /// 只在套了个人筛选时才说得通——没套筛选时 `/listings` 的 total 就是全库
    /// total，那就成了把 `831 live` 换个说法再讲一遍。
    public static func matchingCount(_ n: Int) -> String { String(localized: "\(n) matching", bundle: .module) }

    /// `118 this week`。汇总行里的一段，`new_7d`。
    public static func weekCount(_ n: Int) -> String { String(localized: "\(n) this week", bundle: .module) }

    /// `47 changed`。汇总行里的一段，`changes_24h`。
    public static func changedCount(_ n: Int) -> String { String(localized: "\(n) changed", bundle: .module) }

    /// 汇总行本身：拿 `·` 把有值的几段串起来。
    ///
    /// **拿不到的那几段整段不出现**，不写 `— live`。一行里出现一个破折号，
    /// 读的人得先判断那是"没取到"还是"真的是零"；整段不出现就没有这个问题。
    /// 全都没有时返回 nil，由调用方省掉这一行。
    public static func summaryLine(_ parts: [String?]) -> String? {
        let kept = parts.compactMap { $0 }
        return kept.isEmpty ? nil : kept.joined(separator: " · ")
    }

    /// `avg 19`。中号左栏那一行窄，`vs. 14-day average of 19` 放不下。
    public static func avgShort(_ average: Int) -> String { String(localized: "avg \(average)", bundle: .module) }

    /// `vs. avg 19`。大号那一行里跟在 `+63%` 后面。
    public static func vsAverage(_ average: Int) -> String { String(localized: "vs. avg \(average)", bundle: .module) }

    /// 柱子右端那个标签。
    public static var today: String { String(localized: "today", bundle: .module) }

    // MARK: - 未读那三行
    //
    // 三个名字对着 ``NotificationItem/Kind`` 的 `.book` / `.status` / `.lottery`。
    // `.book` 叫 `New listings` 而不是 `Bookable`：这一格说的是"来了什么通知"，
    // 不是"能不能订"。

    public static var kindNewListings: String { String(localized: "New listings", bundle: .module) }
    public static var kindStatusChanges: String { String(localized: "Status changes", bundle: .module) }

    /// 窄的地方用这个短的。
    ///
    /// **设计稿自己就是这么干的**：4a（macOS 170pt 宽）那张卡写的是
    /// `Status changes`，4b 里那张同样内容但更挤的卡写的是 `Status`。
    /// 而 macOS 真正的小号是 155pt，比稿子还窄 15pt——实测 `Status changes`
    /// 在那儿会被截成 `Status chang…`，所以这一格用短的。
    public static var kindStatusShort: String { String(localized: "Status", bundle: .module) }
    public static var kindLottery: String { String(localized: "Lottery", bundle: .module) }

    /// 大号底部那一条：`Next move-in · 23 Sep`。
    ///
    /// **设计稿那一条原本是 `Lottery closes · Kastanjelaan 400 · in 2d`。**
    /// 换掉的理由和 `CalendarPane` 顶上写的是同一条：openapi 里 `deadline` /
    /// `closes` / `draw_at` 各出现 0 次，listings 表只有 `available_from`
    /// 一个日期列而且只到日。抽签截止时刻这个数据**整条不存在**，
    /// 画出来只能是编的。换成同一个形状里放真有的东西。
    public static func nextMoveInOn(_ date: String) -> String { "\(nextMoveIn) · \(date)" }

    /// `in 6d` / `today`。大号底部那一条右端。
    public static func inDays(_ days: Int) -> String {
        days <= 0 ? today : String(localized: "in \(days)d", bundle: .module)
    }

    /// `vs. 14-day average of 19` 里那句。基准由 ``DailyNew/baselineAverage(_:)`` 给。
    public static func vsBaseline(_ average: Int) -> String {
        String(localized: "vs. 14-day average of \(average)", bundle: .module)
    }

    /// `+63%` / `-12%`。
    public static func percent(_ value: Int) -> String {
        value >= 0 ? "+\(value)%" : "\(value)%"
    }

    // MARK: - 日历

    /// 下一个有货可抢的日子。和 `CalendarPane` 那张卡同名。
    public static var nextMoveIn: String { String(localized: "Next move-in", bundle: .module) }
    /// 可订 + 抽签那一档。`CalendarPane` 的统计带用的是同一个词。
    public static var bookable: String { String(localized: "Bookable", bundle: .module) }
    public static var moveIns: String { String(localized: "Move-ins", bundle: .module) }

    /// `14 days`。日历那格两档尺寸铺的天数不同，合计也就不同——不写清范围的话，
    /// 同一个 `Move-ins` 在中号和大号上是 30 和 74。
    ///
    /// 说天不说周（一度写的是 `next 2 weeks`）：中号左栏只有 140pt，
    /// 那句话在实际渲染里被截成了 `next 2…`。天数更短，而且和柱子的粒度一致——
    /// 一根柱子就是一天。
    public static func spanDays(_ days: Int) -> String { String(localized: "\(days) days", bundle: .module) }

    /// `8 bookable`。单复数不变——`bookable` 是形容词，不跟着数走。
    public static func bookableCount(_ n: Int) -> String { String(localized: "\(n) bookable", bundle: .module) }

    /// 这几天一套能抢的都没有时说的话。
    ///
    /// **不写 "0 bookable"**：那读起来像"今天的结果是零"，而实际是「往后数
    /// 这么多天都没有」——两件事，后者才是真的。
    public static var noneBookable: String { String(localized: "Nothing bookable ahead", bundle: .module) }

    // MARK: - 时间

    /// `scanned 4m ago`。参数是 ``ServerTime/relativeTime(_:now:)`` 的结果。
    ///
    /// **存小写。** 这句话有两种用法：单独成行（菜单栏、小组件那几格），
    /// 和跟在别的东西后面（侧栏是 `7 platforms · scanned 4m ago`）。后者要是
    /// 大写，就成了一句话中间冒出个大写的 `· Scanned 4m ago`。
    ///
    /// 所以大小写是**排版**，由 ``sentence(_:)`` 在单独成行的地方套上——和段标题
    /// 那个 `.textCase(.uppercase)` 是同一类事。为这个存两份字符串才是错的：
    /// 这一轮已经因为「同一句话两个写法」抓到过三处漂移了。
    public static func scanned(_ ago: String) -> String { String(localized: "scanned \(ago)", bundle: .module) }

    /// 单独成行时把首字母提上去。
    ///
    /// 只动第一个字符，不碰其余——`.capitalized` 会把 `831 live · 4m ago`
    /// 变成 `831 Live · 4m Ago`。
    public static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// `checked 3h ago`。**数据过期之后**改说这一句，见
    /// ``WidgetSnapshot/footnote(at:)``——那时候我们只知道自己是几时取的，
    /// 不知道后端是几时扫的，就别替后端发言。
    public static func checked(_ ago: String) -> String { String(localized: "checked \(ago)", bundle: .module) }

    /// 连扫描时间都没拿到时说的话。
    ///
    /// **不写 "scanned unknown"**——那会被读成「扫过了，但不知道什么时候」，
    /// 而实际是「没拿到这条信息」。
    public static var scanTimeUnavailable: String { String(localized: "Last scan time unavailable", bundle: .module) }

    /// 共享容器里什么都没有时说的话。
    ///
    /// 说的是**该做什么**，不是"没有数据"：那一格是空的只有两种原因
    /// （没登录 / 这台机器还没跑过 app），两种的下一步动作是同一个，
    /// 所以不必分辨，直接说那个动作。
    public static var openApp: String { String(localized: "Open FlatRadar", bundle: .module) }
}
