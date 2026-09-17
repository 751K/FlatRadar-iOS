import SwiftUI
import UIKit
import FlatRadarCore

@main
struct FlatRadarApp: App {

    init() {
        // 截图自动化模式（UI Test 启动时传 launch arg "UI_TEST_SCREENSHOT_MODE"）：
        // 跳过条款 sheet / onboarding / biometric / crash prompt，让 App 直接
        // 进入主 UI；并关掉 UIKit 动画提升截图稳定性。
        // 不在生产 build 误触：UI_TEST_SCREENSHOT_MODE 永远只由 UI Test 传，
        // 真实用户启动不会带这个参数。
        if CommandLine.arguments.contains("UI_TEST_SCREENSHOT_MODE") {
            let d = UserDefaults.standard
            d.set(true, forKey: "terms_accepted")
            d.set(true, forKey: "onboarding_completed")
            d.set(true, forKey: "crash_prompt_suppressed")
            UIView.setAnimationsEnabled(false)
        }
    }
    // 监听 App 前后台切换；用于 SSE 在后台主动关、回前台重连。
    @Environment(\.scenePhase) private var scenePhase

    // PushDelegate 桥接：SwiftUI 没有原生 APNs token 钩子，必须挂一个
    // UIApplicationDelegate。@UIApplicationDelegateAdaptor 把它注入到
    // App 生命周期；PushDelegate.init() 会把 self 写进 .shared 供 PushStore 拿。
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate

    @State private var authStore = AuthStore()
    @State private var dashboardStore = DashboardStore()
    @State private var listingsStore = ListingsStore()
    @State private var notificationsStore = NotificationsStore()
    @State private var mapStore = MapStore()
    @State private var calendarStore = CalendarStore()
    @State private var meFilterStore = MeFilterStore()
    @State private var adminStore = AdminStore()
    @State private var pushStore = PushStore()
    @State private var coffeeStore = CoffeeStore()
    @State private var reviewStore = ReviewPromptStore()
    @State private var coordinator = NavigationCoordinator()

    /// User-overridden color scheme. "system" = follow OS.
    @AppStorage("color_scheme") private var colorScheme: String = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(resolvedColorScheme)
                .environment(authStore)
                .environment(dashboardStore)
                .environment(listingsStore)
                .environment(notificationsStore)
                .environment(mapStore)
                .environment(calendarStore)
                .environment(meFilterStore)
                .environment(adminStore)
                .environment(pushStore)
                .environment(coffeeStore)
                .environment(reviewStore)
                .environment(coordinator)
                .task {
                    // 0'. 注入平台信息。必须在任何网络调用之前——`APIClient` 上报
                    //     设备型号 / 系统版本、`/devices/register` 的 platform 字段
                    //     都读它，漏了会发出占位值（DEBUG 下直接断言）。
                    PlatformEnvironment.configure(.iOS)
                    // 0. 注册 MetricKit：上一次 launch 间 OS 收集的崩溃/卡顿
                    //    会在接下来 24h 内通过 didReceive 回调送达。越早注册
                    //    越不会丢漏。清理 7 天前已被拒绝的旧报告。
                    CrashDiagnosticsCollector.shared.start()
                    CrashDiagnosticsCollector.shared.pruneOldDeclined(days: 7)
                    // 1. 全局 401/403 监听 → 自动登出
                    authStore.observeAuthFailures()
                    // 2. 把 PushStore 与 PushDelegate 桥接好（一次性）
                    pushStore.setup(bridge: pushDelegate)
                    // 3. 恢复 token 会话
                    await authStore.restoreSession()
                    // 4. 若已登录（非 guest），自动尝试注册 APNs。
                    //    用户在设置里关过推送就不该再注册——那道门在
                    //    `PushStore.requestPermissionAndRegister` 里面，不在
                    //    这里：注册有六个调用点，条件写在调用点上迟早漏一个。
                    if authStore.isAuthenticated, !authStore.isGuest {
                        await pushStore.requestPermissionAndRegister()
                    }
                    // 5. 预热地图 + 列表数据 —— 用户从 App 启动到第一次点 Browse
                    //    之间的几秒里悄悄把数据拉好。各 view 的 .task 内部检查
                    //    .isEmpty 决定是否再拉、Store.fetch 自带 isLoading guard，
                    //    所以不会和真正的 view appear 打架。非结构化 Task 并发跑，
                    //    不阻塞下面 coffee store 初始化。
                    if authStore.isAuthenticated, !authStore.isGuest {
                        Task { await mapStore.fetch() }
                        Task { await listingsStore.fetch() }
                    }
                    // 6. StoreKit 2 交易监听 + 加载咖啡产品
                    coffeeStore.listenForTransactions()
                    await coffeeStore.loadProducts()
                    // 7. 主屏 / 锁屏小组件那几格的数据。
                    //
                    //    放在最后：它读的是上面那些 store 的现状，早跑一步只会
                    //    写出一份空的。那条 14 天序列是它自己多拉的一样东西
                    //    （公开接口、十几个整数），见 `WidgetPublisher`。
                    await WidgetPublisher.refreshSeries()
                    publishWidgetSnapshot()
                }
                // Deep link 入口 1：用户点击 push 通知 →
                // PushDelegate 已 post 这个事件
                .onReceive(NotificationCenter.default.publisher(
                    for: .flatRadarOpenListing)) { note in
                    guard let id = note.userInfo?["listing_id"] as? String else { return }
                    coordinator.openListing(id: id)
                }
                // Deep link 入口 2：h2smonitor://listing/<id>（推送 payload、旧链接）
                .onOpenURL { url in
                    handleURL(url)
                }
                // Deep link 入口 3：**分享出去的那条链接**
                // `https://<服务器>/l/<id>`，一条 Universal Link。
                //
                // 和入口 2 是两条独立的路，不能只接一条：自定义 scheme 走
                // `onOpenURL`，https 走 `NSUserActivity`。分享发的是这一条，
                // 推送里带的还是那一条，两种都在流通。
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    handleUniversalLink(url)
                }
                // 小组件那几格跟着这几个数走。
                //
                // 写一次很便宜：没有网络，攒个结构体加一次原子写文件，而且
                // `WidgetBridge.publish` 只在数字真变了时才踢时间轴。所以宁可
                // 多挂几个点，也不要让桌面上那一格停在几小时前——它旧了会
                // 自己改口（见 `WidgetSnapshot.footnote(at:)`），但能新就该新。
                .onChange(of: notificationsStore.unreadCount) { publishWidgetSnapshot() }
                .onChange(of: dashboardStore.summary?.lastScrape) { publishWidgetSnapshot() }
                .onChange(of: listingsStore.listings.count) { publishWidgetSnapshot() }
                // SSE 实时通知：登录 + 前台时连，登出 / 后台时断
                .onChange(of: scenePhase) { _, newPhase in
                    syncStreamState(scenePhase: newPhase)
                    // 切后台那一刻写一次：用户刚离开 app，接下来看到的就是
                    // 桌面上那一格。
                    if newPhase == .background { publishWidgetSnapshot() }
                    // 「用过几天」在这里记。放前台切换而不是 App 启动：用户
                    // 常常不退 App，只是切出去再切回来——只在冷启动记的话，
                    // 连用一周可能只算一天。
                    //
                    // 通知状态顺带一起传：ReviewPromptStore 拿不到 PushStore，
                    // 而这里两个都在手上。
                    if newPhase == .active {
                        reviewStore.noteActiveDay(
                            hasNotifications: pushStore.permissionStatus == .authorized
                                || pushStore.permissionStatus == .provisional)
                    }
                }
                .onChange(of: authStore.isAuthenticated) { _, newValue in
                    syncStreamState(scenePhase: scenePhase)
                    if newValue {
                        // 登入路径：从 guest/未登录切到登录态 → 预热 map + listings，
                        // 跟 App 首次启动 .task 里的预热同一处理。
                        if !authStore.isGuest {
                            if mapStore.listings.isEmpty {
                                Task { await mapStore.fetch() }
                            }
                            if listingsStore.listings.isEmpty {
                                Task { await listingsStore.fetch() }
                            }
                        }
                    } else {
                        // 登出路径（手动 logout / 401 自动 / 删号都会走这里）：
                        //
                        // 1. 清空 NavigationCoordinator —— 下个用户登入时不停留
                        //    在上个用户最后看的 tab + 详情栈。
                        // 2. 清空所有 @Observable 数据 store —— 否则下个用户登入
                        //    瞬间会短暂看到上个用户的 listings / notifications /
                        //    map / dashboard，等下个 fetch 才会覆盖，期间数据是
                        //    跨账户泄露的。
                        coordinator.reset()
                        listingsStore.clear()
                        notificationsStore.clear()
                        mapStore.clear()
                        calendarStore.clear()
                        dashboardStore.clear()
                        meFilterStore.clear()
                        // 3. 清掉主屏 / 锁屏那几格。匹配数和未读是账户数据，
                        //    窗口里清干净而桌面上还挂着上一个账号的数字，
                        //    等于这条判据没做完——而且它比 app 里更显眼。
                        WidgetPublisher.clear()
                    }
                }
        }
    }

    /// 见 ``WidgetPublisher``。store 都攥在这一层，所以调用点也在这儿。
    private func publishWidgetSnapshot() {
        WidgetPublisher.publish(auth: authStore,
                                dashboard: dashboardStore,
                                listings: listingsStore,
                                notifications: notificationsStore)
    }

    /// 把 UserDefaults 的字符串映射到 SwiftUI ColorScheme?。
    /// "system" → nil（跟随系统），"light"/"dark" → 对应值。
    private var resolvedColorScheme: ColorScheme? {
        switch colorScheme {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    /// 决定 SSE 是否应保持连接：authenticated && non-guest && foreground active。
    /// 其它情况主动断开，避免后台时网络心跳浪费电。
    private func syncStreamState(scenePhase: ScenePhase) {
        let shouldConnect = authStore.isAuthenticated
            && !authStore.isGuest
            && scenePhase == .active
        if shouldConnect {
            notificationsStore.connectStream()
        } else {
            notificationsStore.disconnectStream()
        }
    }

    /// 别人分享过来的 ``https://<服务器>/l/<id>``。
    ///
    /// 认不出形状就**交还给系统**（在浏览器里打开）。`applinks` 认领的是路径
    /// 前缀，这个域名下用户点过的链接都会送进来；默默吞掉的话，在 Safari 里点
    /// 一个站内链接会变成"点了没反应"。
    private func handleUniversalLink(_ url: URL) {
        guard let id = ListingShare.listingID(fromUniversalLink: url) else {
            UIApplication.shared.open(url)
            return
        }
        coordinator.openListing(id: id)
    }

    /// 解析 ``h2smonitor://listing/<id>``。
    /// 其它 host 暂时忽略（将来可扩展 /map、/notifications 等）。
    private func handleURL(_ url: URL) {
        guard url.scheme == "h2smonitor" else { return }
        switch url.host {
        case "listing":
            let id = url.lastPathComponent
            coordinator.openListing(id: id)
        case "map":
            // h2smonitor://map/<id> —— 直接把地图开到那套房上。
            coordinator.openMap(focusing: url.lastPathComponent)
        default:
            #if DEBUG
            print("[FlatRadarApp] unknown deep link host=\(url.host ?? "")")
            #endif
        }
    }
}
