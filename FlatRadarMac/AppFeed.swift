import SwiftUI
import FlatRadarCore

/// 跨窗口共享的那一层。
///
/// 为什么需要它
/// -----------
/// docs/MACOS.md 风险 6 把状态分成三层，其中**应用级**那一行写得很清楚：
/// 「服务器、账户、认证客户端、推送、个人筛选配置、**通知数据与 SSE**」，
/// 约束是「初始化和监听安装幂等；**每个会话最多一条通知流**」。
///
/// 而 Phase 4 之前的代码不是这样：`NotificationsStore` 和 `SummaryModel` 都是
/// `MainWindow` 的 `@State`。只有一个窗口时两种写法没差别，所以一直没暴露。
/// 一旦 ⌘N 能开第二个窗口，同一份代码就变成：
///
/// - **两条 SSE**。每个窗口的 `.task` 各调一次 `connectStream()`，而那个方法只
///   拦得住"同一个 store 连两次"（`guard streamTask == nil`），拦不住两个 store。
///   后端按连接收费的地方就是这里翻倍的。
/// - **两次 `restoreSession()`**。`RootView.didRestore` 是窗口级 `@State`，
///   第二个窗口一开又跑一遍，而风险 6 第一条就是「登录恢复只执行一次」。
/// - **两份统计请求**。`SummaryModel` 自己的注释里早写了它是「可选共享缓存」
///   那一层的候选，只是当时"只有一个窗口，抽了也验证不了"。现在验证得了了。
///
/// 什么**不**放进来
/// ---------------
/// `BrowseModel`（选择、排序、临时筛选、固定比较项）和三个带查询状态的 store
/// （listings / map / calendar）仍然一窗一份——那正是风险 6 里窗口级那一行，
/// 也是「两个窗口的选择与临时筛选互不覆盖」这条判据的实现方式。
///
/// 通知**数据**共享，但通知的**选中项**（`focusedAlert`）在 `BrowseModel` 里，
/// 所以两个窗口可以同时看 Alerts 屏、各自选中不同的一条。
@MainActor
@Observable
final class AppFeed {

    /// 通知数据 + SSE。一个会话一条流，见类型注释。
    let alerts = NotificationsStore()

    /// 顶部统计带的数据。菜单栏常驻也读它——所以它必须在窗口之外活着。
    let summary = SummaryModel()

    /// 拿 `total` / `isFiltered`，**顺便拿最新那三条**。
    ///
    /// 菜单栏要显示「当前匹配数」，而这个数在**没有任何窗口**时也得有——
    /// 不能从某个 `BrowseModel.listings` 里读。一次 `fetch()` 就能拿到服务端
    /// 算好的 `total`（以及「这个数是不是套了你的个人筛选」），比自己拼一个
    /// `limit=1` 的请求省事，也复用了已经测过的那条路径。
    ///
    /// `pageSize` 从 1 提到 5，是因为设计稿里小组件中号 / 大号和菜单栏面板
    /// 都有一段 NEWEST 列表。**不是多发一个请求**：同一条 `/listings` 顺手多带回
    /// 几条，而它默认就按 `-first_seen` 排（写进契约的），第一页就是最新那几条。
    private let recent = ListingsStore(pageSize: AppFeed.newestCount)

    /// NEWEST 那一段最多放几条。
    ///
    /// 5 是**菜单栏面板**的量（设计稿 t5）；小组件那几档自己再 `prefix` 到 3 / 2。
    /// 取两者的最大值存一份，而不是各拉各的：同一个列表在同一台机器上的两个地方
    /// 显示成不同的内容，是最难解释的那种不一致。
    static let newestCount = 5

    /// 落给小组件的那几条。见 ``newestForWidget``。
    static let widgetNewestCount = 3

    /// 菜单栏面板那一段可点的列表。
    ///
    /// 直接给 ``Listing``（不是小组件那份压扁的 `WidgetListing`）：面板和 app
    /// 在同一个进程里，点一行要开详情窗口，需要 id 之外的东西。压扁那份是为了
    /// 过共享容器那道 JSON，这里没有那道门。
    var recentListings: [Listing] { recent.listings }

    /// 日历数据。**从窗口级提上来的**。
    ///
    /// 它本来是 `MainWindow` 的 `@State`，理由和 `mapStore` 一样（窗口级）。
    /// 提上来有两个理由，都和这一层的定位一致（「只读的展示数据，跟窗口的查询
    /// 状态无关」——`SummaryModel` 顶上写的就是这句）：
    ///
    /// 1. 桌面上那格日历小组件在**一个窗口都没有**的时候也得有数。
    /// 2. 开两个窗口时原先会拉两遍同一个 `/calendar`。
    ///
    /// **选中的是哪一天**仍然在 `BrowseModel.calendarDay` 里，一窗一份——
    /// 提上来的是数据，不是选择。
    public let calendar = CalendarStore()

    /// 小组件那格日历往后铺几天。
    ///
    /// 28 天 = 四周，正好是大号那一格一行七个、四行铺满的量；中号取前 14 天。
    /// 存的是连续序列（空的日子也占一格），所以这个数直接决定文件大小——
    /// 28 个三元组，几百字节。
    static let moveInDays = 28

    var matchCount: Int? { recent.total > 0 ? recent.total : nil }
    var matchIsFiltered: Bool { recent.isFiltered }

    // MARK: - 会话结束 → 清账户数据

    @ObservationIgnored private var sessionEndObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var sessionBeginObserver: (any NSObjectProtocol)?

    /// 装一个「会话结束」的监听，终身一份。
    ///
    /// 风险 6：「任何窗口登出、会话失效……都统一断流、清空所有窗口的账户数据」。
    ///
    /// 原先这件事是**调用点**做的：应用菜单那个 Sign Out 在 `logout()` 之后手动调
    /// ``signedOut()``。可登出不止那一条路——设置页的 Sign Out、Delete Account、
    /// 401 自动登出——另外三条都没调，于是退出之后进游客模式，Alerts 里还是上一个
    /// 账号的通知和未读数（游客那边请求通知会失败，而失败不清旧数据）。
    ///
    /// 改成听 ``AuthStore/sessionEndedNotification``：会话在哪儿结束都一样，
    /// 以后再加一条登出路径也不用记得来这儿。
    ///
    /// 为什么挂在这一层而不是某个窗口的 `.onChange`
    /// -----------------------------------------
    /// 菜单栏常驻现在默认开，**一个窗口都没有**是常态。token 被撤销、下一次后台
    /// 请求 401 → 自动登出，那一刻可能没有任何视图在场；挂在窗口上的监听不会跑，
    /// SSE 也就没人断。
    init() {
        sessionEndObserver = NotificationCenter.default.addObserver(
            forName: AuthStore.sessionEndedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.signedOut() }
        }
        // 会话**开始**时重新判断 SSE。
        //
        // 窗口里的 `RootView` 也会做同一件事，但菜单栏常驻、一个窗口都没有的时候
        // 它不存在——而游客正好可能在只开着设置窗口时注册。`syncStream` 幂等，
        // 两处都调没关系。
        sessionBeginObserver = NotificationCenter.default.addObserver(
            forName: AuthStore.sessionBeganNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let auth = note.object as? AuthStore else { return }
            Task { @MainActor in self?.syncStream(auth: auth) }
        }
    }

    // MARK: - 一次性的启动动作

    private var didRestore = false

    /// 风险 6 第一条：「登录恢复只执行一次」。
    ///
    /// 这个 flag 原先在 `RootView` 里，是**窗口级**的 `@State`——第二个窗口一开
    /// 就又恢复一次会话。移到这里之后，无论开几个窗口、无论哪个先出现，
    /// `restoreSession()` 都只跑一遍。
    ///
    /// 收的是**闭包**不是 `AuthStore`：这样测试里能传一个只记数的闭包，
    /// 不必真去碰钥匙串。「只跑一次」这件事本身和恢复什么无关。
    func restoreOnce(_ work: () async -> Void) async {
        guard !didRestore else { return }
        didRestore = true
        await work()
    }

    // MARK: - 内容窗口的计数

    /// 现在开着几个**内容**窗口（登录屏不算）。
    ///
    /// 用它决定 SSE 该不该活着，见 ``syncStream(auth:)``。计数而不是布尔：
    /// 关掉两个窗口里的一个，流不能断。
    private(set) var contentWindows = 0

    func windowAppeared(auth: AuthStore) {
        contentWindows += 1
        syncStream(auth: auth)
    }

    func windowDisappeared(auth: AuthStore) {
        contentWindows = max(0, contentWindows - 1)
        syncStream(auth: auth)
    }

    // MARK: - SSE 的生死

    /// 菜单栏常驻开着没有。由 `FlatRadarMacApp` 从 `@AppStorage` 灌进来。
    ///
    /// 风险 6：「Phase 4 启用菜单栏常驻后，**没有内容窗口也可维持连接**」。
    /// 所以这个开关是 SSE 生死判断的一部分，不只是个显示选项。
    var menuBarResident = false {
        didSet { if let auth = lastAuth { syncStream(auth: auth) } }
    }

    /// 最近一次判断用的 `AuthStore`。
    ///
    /// `menuBarResident` 的 `didSet` 需要它，而 `didSet` 拿不到参数。
    /// 存 `unowned` 会在登出重建时悬垂，存强引用又会和 App 形成环——但
    /// `AuthStore` 的生命周期就是整个进程，环了也无所谓，这里取最简单的写法。
    private var lastAuth: AuthStore?

    /// 按「该不该有流」这一个判断去连或断。
    ///
    /// 三个条件全是风险 6 的原文：
    /// 1. 已登录 —— 没 bearer 连不上，`connectStream()` 自己也会拒。
    /// 2. **不是访客** —— 「游客始终不连接个人流」。
    /// 3. 至少一个内容窗口**或**菜单栏常驻着 —— 「最后一个窗口关闭且尚未启用
    ///    菜单栏常驻时断流；重开窗口时重连并补页」。
    ///
    /// 写成一个幂等的「同步」而不是散在各处的 connect/disconnect 调用：
    /// 开窗、关窗、登录、登出、切常驻开关全都只调它，不会漏掉某一条路径。
    /// `connectStream()` 和 `disconnectStream()` 本身都是幂等的。
    func syncStream(auth: AuthStore) {
        lastAuth = auth
        if Self.wantsStream(authenticated: auth.isAuthenticated,
                            isGuest: auth.isGuest,
                            contentWindows: contentWindows,
                            menuBarResident: menuBarResident) {
            alerts.connectStream()
        } else {
            alerts.disconnectStream()
        }
    }

    /// 上面那个判断本身，抽成纯函数。
    ///
    /// 抽出来是为了**能测**：真去连一条 SSE 要有 token、要有网、要有后端，
    /// 而这条规则里没有一个字和网络有关——它是 docs/MACOS.md 风险 6 的四句话
    /// 翻译成的一个布尔表达式，值得被钉住。
    nonisolated static func wantsStream(authenticated: Bool,
                                        isGuest: Bool,
                                        contentWindows: Int,
                                        menuBarResident: Bool) -> Bool {
        guard authenticated else { return false }
        // 「游客始终不连接个人流」。
        guard !isGuest else { return false }
        // 「至少有一个内容窗口打开时维持 SSE……最后一个窗口关闭且尚未启用
        // 菜单栏常驻时断流」——反过来说，常驻着就可以没有窗口。
        return contentWindows > 0 || menuBarResident
    }

    // MARK: - 取数

    /// 启动时拉一次共享数据。幂等：第二个窗口出现时再调不会重复发请求。
    func loadOnce(auth: AuthStore) async {
        async let stats: Void = summary.load()
        async let feed: Void = alerts.fetch()
        async let count: Void = refreshMatchCount()
        async let days: Void = fetchCalendarIfWidgetInstalled()
        _ = await (stats, feed, count, days)
        publishWidgetSnapshot(auth: auth)
    }

    /// 只有桌面上真摆着日历那一格时才去拉 `/calendar`。
    ///
    /// `MainWindow` 里那条注释是量过的：这个接口回 691 条、211 KB，是四屏里
    /// 最少打开的一屏，所以刻意没跟着启动一起发。这里**不推翻那个决定**——
    /// 没摆那一格就一个字节都不多要；摆了的人自己承担这一次请求，
    /// 那正是他要的那格数据。
    ///
    /// `force` 给 ⌘R 和菜单栏的刷新用：那是用户明确要求的一次刷新，
    /// 该把手上所有数据都过一遍，而 `fetch()` 的 `guard !isLoading` 去重还在。
    ///
    /// `forPanel` 是菜单栏面板发起的那一次刷新。面板底部那条横幅要日历数据，
    /// 所以它自己就是理由，不看有没有摆日历小组件。
    private func fetchCalendarIfWidgetInstalled(force: Bool = false,
                                               forPanel: Bool = false) async {
        // ⚠️ 判据是「**面板被打开了**」，不是「菜单栏常驻开着」。
        //
        // 常驻现在默认开（见 ``MenuBarResidency/defaultOn``），拿它当判据就等于
        // 每次启动都发这个 211 KB 的请求——上面那个"没摆就一个字节都不多要"的
        // 决定会被默认值悄悄推翻。而菜单栏上那个**图标**并不显示入住日，只有点开
        // 的面板才显示，所以该付这次请求的时刻就是点开那一下。
        if !forPanel {
            guard await WidgetBridge.isInstalled(kind: WidgetKind.calendar) else { return }
        }
        if force || calendar.listings.isEmpty {
            await calendar.fetch()
        }
    }

    func refreshMatchCount() async {
        guard !recent.isLoading else { return }
        await recent.fetch()
    }

    /// 菜单栏面板的刷新，以及窗口里 ⌘R 的连带刷新。
    ///
    /// `forPanel` 只有面板那条路会传 true，它比 ⌘R 多要一份日历——面板底部有
    /// 那条「下一个能抢的入住日」，窗口里没有。
    func refreshShared(auth: AuthStore, forPanel: Bool = false) async {
        async let stats: Void = summary.load()
        async let count: Void = refreshMatchCount()
        async let days: Void = fetchCalendarIfWidgetInstalled(force: true, forPanel: forPanel)
        _ = await (stats, count, days)
        publishWidgetSnapshot(auth: auth)
    }

    /// 登出时把共享数据清干净。
    ///
    /// 风险 6：「任何窗口登出……都统一断流、**清空所有窗口的账户数据**」。
    /// 通知是账户数据，统计不是（`/stats/public/*` 不需要 bearer），所以只清前者。
    ///
    /// 桌面上那一格也是账户数据，而且**比窗口更显眼**——窗口里清干净了，
    /// 上一个账号的匹配数还挂在桌面上，那条判据就没做完。
    func signedOut() {
        alerts.disconnectStream()
        alerts.clear()
        recent.clear()
        calendar.clear()
        WidgetBridge.clear()
    }

    // MARK: - 桌面小组件

    /// 把手上这份共享数据整个落给小组件。
    ///
    /// 为什么是**这一层**在写：小组件要的三样（匹配数、口径、上次扫描时间）
    /// 正好就是 `AppFeed` 存在的理由——「没有任何窗口时也得有」。换成在某个
    /// 视图里写，关掉窗口那条路就断了，而菜单栏常驻恰恰是没有窗口的那种形态。
    ///
    /// `auth` 显式传进来，不读 ``lastAuth``：那个字段只在 ``syncStream(auth:)``
    /// 跑过之后才有值，而 `loadOnce` 和它谁先跑没有保证。为一个能直接传的参数
    /// 去赌时序不值得。
    func publishWidgetSnapshot(auth: AuthStore) {
        let now = Date()
        WidgetBridge.publish(WidgetSnapshot(
            newToday: summary.newToday,
            dailyNew: summary.series,
            totalListings: summary.summary?.total,
            statusChanges: summary.summary?.changes24h,
            matchCount: matchCount,
            isFiltered: matchIsFiltered,
            unreadAlerts: alerts.unreadCount,
            // 访客没有个人通知流，那个数永远是 0。和菜单栏那一行同一个判断。
            showsUnread: !auth.isGuest,
            newest: newestForWidget,
            unreadKinds: auth.isGuest ? .none : unreadKindsForWidget,
            moveIns: MoveInDay.series(listingsByDay: calendar.listingsByDay,
                                      from: now, days: Self.moveInDays),
            lastScrape: summary.summary?.lastScrape ?? "",
            capturedAt: now))
    }

    /// NEWEST 三行。
    ///
    /// 只搬画得出来的五个字段，不搬整个 `Listing`——那玩意带 features /
    /// featureMap / 坐标，几百字节一条，而共享容器那份 JSON 每次刷新都整份重写。
    private var newestForWidget: [WidgetListing] {
        // 3 而不是 ``newestCount``（5）。那 5 条是菜单栏面板要的，小组件最多画 3 行
        // （Mac 大号 3、手机大号 2）。多带的两条要整份重写进共享容器，每次刷新
        // 都付一遍这个字节数，而没有任何一档会画出来。
        recent.listings.prefix(Self.widgetNewestCount).map { listing in
            WidgetListing(id: listing.id,
                          name: listing.name,
                          city: listing.city,
                          platform: Platform.displayName(listing.source),
                          price: listing.priceRaw ?? "",
                          firstSeen: listing.firstSeen ?? "")
        }
    }

    /// 未读按类别拆开。
    ///
    /// 用的是 `NotificationItem.kind`，**不再自己判一遍**——那个分类是后端
    /// `type` 加正文启发式判出来的，判错过一次（`new_listing` 正文里那个 `→`
    /// 是入住日、被当成状态迁移，Mac 实测 17 条全判成 Status），已经修在包里。
    ///
    /// 数的是**已经拉回本地**的未读。`NotificationsStore.fetch()` 会一直翻页到
    /// `unreadCount <= loadedUnreadCount` 为止，所以正常情况下这三个数加起来
    /// 就等于头条那个数；翻页失败时头条那个才是对的，这三行只是没数全。
    private var unreadKindsForWidget: UnreadBreakdown {
        let unread = alerts.notifications.filter { !$0.isRead }
        return UnreadBreakdown(
            newListings: unread.filter { $0.kind == .book }.count,
            statusChanges: unread.filter { $0.kind == .status }.count,
            lottery: unread.filter { $0.kind == .lottery }.count)
    }
}
