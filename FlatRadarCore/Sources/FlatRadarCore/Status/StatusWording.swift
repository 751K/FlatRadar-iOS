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

    // MARK: - 匹配数

    /// 套了个人筛选叫 `Matching filters`，没套叫 `Listings`。
    ///
    /// 两处说法不一致的话，用户会以为那是两个数。
    public static func countLabel(isFiltered: Bool) -> String {
        isFiltered ? "Matching filters" : "Listings"
    }

    /// 拿不到就是 `—`，**不是 `0`**。
    ///
    /// 0 是「一套都没匹配上」，那是个事实；拿不到不是事实，是没拿到。
    public static func countText(_ count: Int?) -> String {
        count.map(String.init) ?? "—"
    }

    // MARK: - 统计带上那四个标题

    /// 锚点。设计稿 t3 的原话：「打开 app 第一眼要看的是"现在有什么新的"」。
    public static let newToday = "New today"
    /// 全库，不是这个账号的。标签把口径写在脸上——实测库里 828 条而账号只匹配 80 条。
    public static let totalListings = "Total listings"
    public static let statusChanges = "Status changes"
    public static let unread = "Unread"

    // MARK: - 小组件那几段的标题
    //
    // 设计稿里它们是全大写的等宽小标签，但**这里存的是正常大小写**——
    // 大写是排版（`.textCase(.uppercase)`），不是文案。存大写的话，同一句话在
    // 统计带（`New today`）和小组件（`NEW TODAY`）就成了两个字符串常量。

    /// NEWEST 那三行的段标题。
    public static let newest = "Newest"
    /// 大号那三格里的第一格。就是全库房源数，换了个更口语的说法——
    /// 那一格窄，`Total listings` 放不下。
    public static let liveNow = "Live now"

    /// `831 live`。小号底下那行的前半句。
    public static func liveCount(_ n: Int) -> String { "\(n) live" }

    /// `avg 19`。中号左栏那一行窄，`vs. 14-day average of 19` 放不下。
    public static func avgShort(_ average: Int) -> String { "avg \(average)" }

    /// `vs. avg 19`。大号那一行里跟在 `+63%` 后面。
    public static func vsAverage(_ average: Int) -> String { "vs. avg \(average)" }

    /// 柱子右端那个标签。
    public static let today = "today"

    // MARK: - 未读那三行
    //
    // 三个名字对着 ``NotificationItem/Kind`` 的 `.book` / `.status` / `.lottery`。
    // `.book` 叫 `New listings` 而不是 `Bookable`：这一格说的是"来了什么通知"，
    // 不是"能不能订"。

    public static let kindNewListings = "New listings"
    public static let kindStatusChanges = "Status changes"

    /// 窄的地方用这个短的。
    ///
    /// **设计稿自己就是这么干的**：4a（macOS 170pt 宽）那张卡写的是
    /// `Status changes`，4b 里那张同样内容但更挤的卡写的是 `Status`。
    /// 而 macOS 真正的小号是 155pt，比稿子还窄 15pt——实测 `Status changes`
    /// 在那儿会被截成 `Status chang…`，所以这一格用短的。
    public static let kindStatusShort = "Status"
    public static let kindLottery = "Lottery"

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
        days <= 0 ? "today" : "in \(days)d"
    }

    /// `vs. 14-day average of 19` 里那句。基准由 ``DailyNew/baselineAverage(_:)`` 给。
    public static func vsBaseline(_ average: Int) -> String {
        "vs. 14-day average of \(average)"
    }

    /// `+63%` / `-12%`。
    public static func percent(_ value: Int) -> String {
        value >= 0 ? "+\(value)%" : "\(value)%"
    }

    // MARK: - 日历

    /// 下一个有货可抢的日子。和 `CalendarPane` 那张卡同名。
    public static let nextMoveIn = "Next move-in"
    /// 可订 + 抽签那一档。`CalendarPane` 的统计带用的是同一个词。
    public static let bookable = "Bookable"
    public static let moveIns = "Move-ins"

    /// `14 days`。日历那格两档尺寸铺的天数不同，合计也就不同——不写清范围的话，
    /// 同一个 `Move-ins` 在中号和大号上是 30 和 74。
    ///
    /// 说天不说周（一度写的是 `next 2 weeks`）：中号左栏只有 140pt，
    /// 那句话在实际渲染里被截成了 `next 2…`。天数更短，而且和柱子的粒度一致——
    /// 一根柱子就是一天。
    public static func spanDays(_ days: Int) -> String { "\(days) days" }

    /// `8 bookable`。单复数不变——`bookable` 是形容词，不跟着数走。
    public static func bookableCount(_ n: Int) -> String { "\(n) bookable" }

    /// 这几天一套能抢的都没有时说的话。
    ///
    /// **不写 "0 bookable"**：那读起来像"今天的结果是零"，而实际是「往后数
    /// 这么多天都没有」——两件事，后者才是真的。
    public static let noneBookable = "Nothing bookable ahead"

    // MARK: - 时间

    /// `scanned 4m ago`。参数是 ``ServerTime/relativeTime(_:now:)`` 的结果。
    public static func scanned(_ ago: String) -> String { "scanned \(ago)" }

    /// `checked 3h ago`。**数据过期之后**改说这一句，见
    /// ``WidgetSnapshot/footnote(at:)``——那时候我们只知道自己是几时取的，
    /// 不知道后端是几时扫的，就别替后端发言。
    public static func checked(_ ago: String) -> String { "checked \(ago)" }

    /// 连扫描时间都没拿到时说的话。
    ///
    /// **不写 "scanned unknown"**——那会被读成「扫过了，但不知道什么时候」，
    /// 而实际是「没拿到这条信息」。
    public static let scanTimeUnavailable = "Last scan time unavailable"

    /// 共享容器里什么都没有时说的话。
    ///
    /// 说的是**该做什么**，不是"没有数据"：那一格是空的只有两种原因
    /// （没登录 / 这台机器还没跑过 app），两种的下一步动作是同一个，
    /// 所以不必分辨，直接说那个动作。
    public static let openApp = "Open FlatRadar"
}
