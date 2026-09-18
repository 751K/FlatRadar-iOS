import SwiftUI
import AppKit
import FlatRadarCore

/// macOS 客户端入口。
///
/// 应用级状态是 ``AuthStore``（服务器 / 账户 / 认证）和 ``PushStore``（这台 Mac
/// 的 APNs 注册），窗口级的一切在 ``BrowseModel`` 里——docs/MACOS.md 风险 6 的划分。
/// 带查询状态的 `ListingsStore` 不做全局单例，否则将来两个窗口会互相覆盖排序和筛选。
///
/// 推送是**应用级**的：一台 Mac 一个 device token，不随窗口数变。
@main
struct FlatRadarMacApp: App {

    @State private var auth = AuthStore()
    @State private var push = PushStore()
    /// 打赏和评分都是**应用级**的：一台 Mac 一份商品列表、一份"问过没有"的
    /// 计数，不随窗口数变。和 `push` 同一个理由。
    @State private var coffee = CoffeeStore()
    @State private var review = ReviewPromptStore()
    /// 通知筛选的保存状态。只有设置页用，但放应用级：设置窗口和主窗口是两个场景，
    /// 放进任何一个窗口里，另一个都拿不到。
    @State private var filterStore = MeFilterStore()

    /// 跨窗口共享的通知流、统计和匹配数。见 ``AppFeed``——Phase 4 开多窗口之前
    /// 这些东西都挂在 `MainWindow` 的 `@State` 上，两个窗口会各连一条 SSE。
    @State private var feed = AppFeed()

    /// 菜单栏常驻。场景的存在与否要在 `body` 里判断，所以这个开关读在 App 这一层。
    @AppStorage(MenuBarResidency.storageKey) private var menuBarResident = MenuBarResidency.defaultOn

    /// 主窗口场景的 id。菜单栏那个「Open FlatRadar」用它重开窗口。
    static let mainWindowID = "main"

    /// 房源详情窗口场景的 id。
    static let listingWindowID = "listing"

    /// Help 菜单那条的动作：给 support 写信，主题里带上版本。
    ///
    /// 带版本是为了收信的人少问一轮——Mac 版和 iOS 版号是分开的（`1.0.0` vs
    /// `2.2.0`），只说"FlatRadar"看不出是哪一端。
    ///
    /// 拆成 URL 和"打开"两步，是为了前一半能测。要防的是把地址放进
    /// `c.host`——那样拼出来是 `mailto://support@…`，多两个斜杠就不是合法的
    /// mailto 了，而代码读起来和正确写法一模一样。见 `SupportMailTests`。
    static var supportMailURL: URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = supportAddress
        c.queryItems = [URLQueryItem(name: "subject",
                                     value: "FlatRadar for Mac \(AppVersion.short) — Support")]
        return c.url
    }

    /// 和条款里写的是同一个地址（`LegalText`），不另造一个。
    static let supportAddress = "support@flatradar.app"

    static func openSupportMail() {
        guard let url = supportMailURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// APNs token 只能从 app delegate 拿到。实例由 SwiftUI 构造并持有，
    /// 通过 ``RootView`` 交给 ``PushStore/setup(bridge:)``。
    @NSApplicationDelegateAdaptor(MacPushDelegate.self) private var pushDelegate

    /// 无头钥匙串自检的启动参数。
    ///
    /// 为什么要有它：钥匙串能不能用，取决于**签名后的这个 app** 拿到了什么
    /// entitlements——data protection 钥匙串要 `application-identifier`。
    /// 在包测试里跑 `KeychainDiagnostics` 证明不了这件事：`swift test` 的
    /// 可执行文件既不是这个 bundle ID、也没有这套 entitlements。
    ///
    /// 所以把自检做成能从命令行触发的模式，跑的就是真正签过名的那个二进制：
    ///
    ///     FlatRadarMac.app/Contents/MacOS/FlatRadarMac --keychain-selftest
    ///
    /// 照搬 `PushStore` 里 `UI_TEST_SCREENSHOT_MODE` 的既有做法。
    static let selfTestFlag = "--keychain-selftest"

    init() {
        if CommandLine.arguments.contains(Self.selfTestFlag) {
            let t = KeychainDiagnostics.run()
            for step in t.steps { print(step) }
            print("UserDefaults 回退 token: "
                  + (KeychainDiagnostics.hasUserDefaultsFallbackToken ? "有（不该有）" : "无"))
            print(t.allPassed ? "RESULT: PASS" : "RESULT: FAIL")
            exit(t.allPassed ? 0 : 1)
        }
        // 必须在**任何**网络调用之前。`APIClient` 上报设备型号 / 系统版本、
        // `/devices/register` 的 platform 字段都读它；漏了会发出占位值，
        // 而 Release 构建里 `assertionFailure` 不生效，后端就默默存了脏数据。
        //
        // 放 init 而不是视图的 .task：.task 在窗口出现后才跑，而
        // `restoreSession()` 也在 .task 里——两者的先后顺序没有保证。
        PlatformEnvironment.configure(.macOS)

        // App Store 截图模式。见 ``ScreenshotMode``——必须在**任何视图挂载之前**
        // 写这些默认值，条款 sheet 和 onboarding 在第一帧就会判断它们。
        ScreenshotMode.applyProcessDefaults()

        if CommandLine.arguments.contains(Self.sessionReportFlag) {
            Self.reportSessionAndExit()
        }
    }

    /// 无头版「重启还能不能恢复会话」。
    ///
    /// docs/MACOS.md Phase 1 的完成判据里有「重新启动能恢复会话，登出后不能恢复
    /// 旧会话」。这两条只能**重启**才验得了，而 GUI 里的验证要人盯着看。
    /// 有了它就是两条命令：
    ///
    ///     FlatRadarMac --session-report   # 登录后：RESTORED
    ///     # 在 app 里 Sign Out，再跑一次  → NO SESSION
    static let sessionReportFlag = "--session-report"

    @MainActor
    private static func reportSessionAndExit() -> Never {
        let auth = AuthStore()
        let state = SessionReportState()

        Task { @MainActor in
            await auth.restoreSession()
            state.authenticated = auth.isAuthenticated
            state.name = auth.userInfo?.name
            state.done = true
        }

        // `init()` 就跑在主线程上，而 `restoreSession()` 是 MainActor 隔离的——
        // 用信号量阻塞会死锁（等的就是自己这条线程）。改成把主 run loop 泵起来，
        // 主 actor 的执行器就是它，泵一下上面那个 Task 才有机会跑。
        let deadline = Date().addingTimeInterval(20)
        while !state.done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if !state.done {
            print("RESULT: TIMEOUT — restoreSession 20 秒没返回")
            exit(2)
        }
        // 只报用户名，不报 token。
        print(state.authenticated
              ? "RESULT: RESTORED — 会话已从钥匙串恢复，用户 \(state.name ?? "?")"
              : "RESULT: NO SESSION — 钥匙串里没有可用会话")
        print("UserDefaults 回退 token: "
              + (KeychainDiagnostics.hasUserDefaultsFallbackToken ? "有（不该有）" : "无"))
        exit(state.authenticated ? 0 : 1)
    }

    var body: some Scene {
        WindowGroup("FlatRadar", id: Self.mainWindowID) {
            RootView(pushBridge: pushDelegate)
                .environment(auth)
                .environment(push)
                .environment(feed)
                .environment(coffee)
                .environment(review)
        }
        // 设计稿画的就是 1440×900。三栏加起来的下限：侧栏 196 + 表格九列约 620
        // + inspector 300 ≈ 1120，再窄就得先收 inspector。
        .defaultSize(width: 1440, height: 900)
        .commands {
            // 命令读的是**当前聚焦那个窗口**的 model（focusedSceneValue），
            // 所以将来开多窗口时 ⌘R 刷新的是你正在看的那一个。
            CommandGroup(after: .toolbar) {
                BrowseCommands()
            }
            // 登出。**Mac 端此前根本没有这个入口**——`AuthStore.logout()` 只在
            // iOS 的 SettingsView 里被调用过，Mac 上登录了就再也回不到登录屏，
            // 除非去删钥匙串。做了登录页却没有回去的路，等于半个功能。
            //
            // 放在应用菜单（`.appSettings` 之后）而不是某个界面里：Mac 上
            // 「账号」这类命令的惯例位置就是应用菜单，而且这一屏是全窗口切换的，
            // 没有一个自然的界面角落安放它。
            //
            // 锚在 `before: .systemServices`，不锚 `after: .appSettings`：有了 `Settings`
            // 场景之后，后者实测排在 **Settings… 上面**（About → Sign Out → Settings…），
            // 登出跑到了设置前头。
            CommandGroup(before: .systemServices) {
                SignOutCommand(auth: auth, push: push)
                Divider()
            }
            // 侧栏那五屏的键盘入口，落在系统自动生成的 View 菜单里——
            // Mac 上「切换视图」这类命令的惯例位置就是那儿。
            //
            // ⚠️ 锚点必须是 `.sidebar`，**不能是 `.toolbar`**。原先写的是
            // `CommandGroup(before: .toolbar)`，结果这五条**整组不出现**：
            // 这个 app 没有 AppKit 意义上的 toolbar（`.toolbar` 修饰符给的是
            // SwiftUI 工具栏，不生成 `Show Toolbar` / `Customize Toolbar…`），
            // 那个命令组根本不存在，`before:` 一个不存在的锚点等于没挂上。
            //
            // **而且是静默的**：菜单里没有这五条，⌘1–⌘5 也一起失效（快捷键是
            // 菜单项注册的），编译不报错、运行不报错。实测过：改锚点前
            // View 菜单只有 `Show Tab Bar / Show All Tabs / Reload Listings /
            // Filter… / Enter Full Screen`，按 ⌘5 没反应；改成 `.sidebar` 之后
            // `Listings / Map / Calendar / Alerts / Stats` 五条就位。
            //
            // 同一个文件里 `BrowseCommands` 用的是 `after: .toolbar`，它反而
            // 落得下来——`after:` 一个空组仍然有落点，`before:` 没有。
            CommandGroup(after: .sidebar) {
                PaneCommands()
                Divider()
                SectionCommands()
                Divider()
            }
            CommandMenu("Listing") {
                ListingCommands()
            }
            // Help 菜单默认只有一条 `FlatRadarMac Help`，而这个 app **没有
            // help book**（Info.plist 里没有 `CFBundleHelpBookName`，产物的
            // Resources 里也没有 `.help` 包）——点下去只会弹一句「帮助不可用」。
            //
            // 一条点了没反应的菜单项比没有这个菜单更糟：它承诺了不存在的东西。
            // 换成真的能用的那个入口。`flatradar.app/legal` 实测 404，站上也没有
            // 文档页，所以能给的只有邮件；地址和条款里写的是同一个
            // （`LegalText`），不另造一个。
            CommandGroup(replacing: .help) {
                Button("Contact Support…") { Self.openSupportMail() }
            }
        }

        // 房源详情窗口。**按 id 去重**：同一条房源再开一次是激活已有那个窗口，
        // 这正好落实风险 6 里「优先激活已显示该房源的窗口」。
        //
        // `Listing.ID` 是 `String`，满足 `Codable & Hashable`，所以窗口能被系统
        // 的状态恢复带过重启。
        WindowGroup(id: Self.listingWindowID, for: Listing.ID.self) { $id in
            ListingWindow(id: id)
                .environment(auth)
        }
        .defaultSize(width: 420, height: 620)
        // 详情窗口里没有侧栏、没有 inspector、没有四屏可切——上面那些命令
        // 一个都不适用。不移掉的话 ⌘1 在这种窗口里是个灰着的死项。
        .commandsRemoved()

        // ⌘,。`Settings` 是独立场景，`WindowGroup` 里注入的环境值到不了这里，
        // 要再注入一遍。
        Settings {
            SettingsView()
                .environment(auth)
                .environment(push)
                .environment(filterStore)
                .environment(coffee)
                .environment(review)
        }

        // 菜单栏常驻。**默认开**（见 ``MenuBarResidency/defaultOn``）。
        //
        // 开关直接决定这个场景在不在 `body` 里：SwiftUI 会据此加上 / 摘掉菜单栏
        // 那一格，不需要自己管 `NSStatusItem`。同一个开关还喂给 ``AppFeed``，
        // 因为风险 6 说常驻之后「没有内容窗口也可维持连接」——图标在不在，
        // 和流断不断，是同一个决定。
        //
        // ⚠️ `isInserted:` 收的是 **Binding**，SwiftUI 会**往回写**：用户把那一格
        // 从菜单栏拖出去，它就把 false 写进 `@AppStorage`。所以一旦这个键落了盘，
        // 改上面那个默认值对**已经跑过旧版本的机器**没有作用——存着的值优先。
        // 实测就是这样：默认改成 true、装上、起来，菜单栏仍然没有那一格；
        // 用 `-menuBarResident YES`（NSArgumentDomain 优先级最高）起一次就出来了。
        // 新默认值只对**没有这个键**的安装生效。
        //
        // 那一趟强制启动同时也是**修法**：往回写这条路径会把 true 落盘，
        // 之后正常启动也带着那一格。所以一台受影响的机器只要
        //
        //     open -a FlatRadarMac --args -menuBarResident YES
        //
        // 起一次就够了，等价于在设置页点一下那个开关。
        MenuBarExtra(isInserted: $menuBarResident) {
            MenuBarStatusView(feed: feed, auth: auth)
        } label: {
            MenuBarStatusLabel(feed: feed, auth: auth)
        }
        .menuBarExtraStyle(.window)
    }
}

/// `reportSessionAndExit` 的可变状态。全在主 actor 上，所以不需要任何同步。
@MainActor
private final class SessionReportState {
    var done = false
    var authenticated = false
    var name: String?
}

// MARK: - 窗口

/// 按登录态分流：登录了看表格，没登录看登录页。
/// 恢复会话期间的占位。
///
/// 它存在的唯一理由是**这段时间不要把登录表单摆出来**：那个
/// `.textContentType(.password)` 的输入框一旦成为新窗口的第一响应者，macOS
/// 就会弹出密码自动填充建议，而它是一个独立的系统窗口，主界面换上来之后
/// 它还浮在房源列表上面。详见 ``AuthStore/isRestoringSession``。
///
/// 转圈**延后 0.6 秒**才出现：本机恢复通常两三百毫秒就完了，让它闪一下再
/// 消失比不转还晃眼。真等久了（网络慢）才需要告诉用户"在做事"。
private struct SessionRestorePane: View {
    @State private var showsSpinner = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if showsSpinner {
                ProgressView()
                    .controlSize(.large)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeIn(duration: 0.2)) { showsSpinner = true }
        }
    }
}

private struct RootView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(PushStore.self) private var push
    @Environment(AppFeed.self) private var feed
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    /// 还没登录就点进来的那条 deep link。
    ///
    /// 风险 6：「URL 与通知路由在未登录时暂存，认证后再执行」。冷启动点链接时
    /// 系统先把 app 拉起来，那一刻 `restoreSession()` 还没跑完——直接丢掉的话，
    /// 用户看到的是"点了链接，App 开了，但停在列表首页"。
    @State private var pendingDeepLink: URL?

    /// 「通知没打开」弹窗。
    @State private var showNotificationsOff = false
    /// 这次启动里弹过没有。**一次启动最多弹一次**：用户点了 Not Now 就是知道了，
    /// 之后切回前台还弹就成了骚扰。
    @State private var didOfferNotificationSettings = false
    /// 用户勾了「不再提醒」。**跨启动**，存 UserDefaults。
    ///
    /// 有人是故意把通知关掉的，每次打开都被问一遍就是骚扰。按 Mac 的惯例做成
    /// 弹窗里的勾选框（`dialogSuppressionToggle`，系统弹窗那个「不再显示此信息」），
    /// 不做成第三个按钮：勾上之后点哪个按钮离开都算数，包括「打开系统设置」。
    ///
    /// 按这台 Mac 存，不按账号——通知权限本来就是这台 Mac 的，不是账号的。
    @AppStorage(NotificationPreferences.alertSuppressedKey) private var notificationsAlertSuppressed = false

    let pushBridge: MacPushDelegate

    /// 这一刻该不该有推送注册。访客没有 bearer，`/devices/register` 调不通；
    /// 登出后也不该再注册。
    ///
    /// 「用户自己关掉了推送」这一条**不在这里判**：那道门在
    /// ``PushStore/requestPermissionAndRegister()`` 里面。注册有六个调用点，
    /// 条件写在调用点上迟早漏一个——原先 iOS 的 bug 正是冷启动那一处漏了。
    private var wantsPush: Bool { auth.isAuthenticated && !auth.isGuest }

    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system.rawValue

    /// 菜单栏常驻。这里读它只为一件事：把值同步给 ``AppFeed``，让它知道
    /// 「最后一个窗口关掉之后流要不要留着」。图标本身由 App 那一层的场景管。
    @AppStorage(MenuBarResidency.storageKey) private var menuBarResident = MenuBarResidency.defaultOn

    /// 跑在 XCTest 的宿主进程里。
    ///
    /// `FlatRadarMacTests` 的 `TEST_HOST` 就是这个 app，跑单测会真的启动它、
    /// 真的从钥匙串恢复会话——这台开发机是登录着的，不拦的话**每跑一次单测**
    /// 就会弹一次通知权限框、往后端注册一台设备。
    private static let isUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// 别人分享过来的 `https://<服务器>/l/<id>`。
    ///
    /// 认不出形状就**交还给浏览器**。系统把这个域名下用户点过的链接都送进来
    /// （`applinks` 认领的是路径前缀），在浏览器里点 `/stats` 之类的站内链接时
    /// 默默吞掉的话，用户看到的是"点了没反应"。
    private func handleUniversalLink(_ url: URL) {
        guard let id = ListingShare.listingID(fromUniversalLink: url) else {
            openURL(url)
            return
        }
        guard auth.isAuthenticated else {
            pendingDeepLink = url
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: FlatRadarMacApp.listingWindowID, value: id)
    }

    /// 解析 `h2smonitor://listing/<id>` 和 `h2smonitor://map/<id>`。
    ///
    /// 和 iOS 的 `handleURL` 认同一套 host，但**落点不一样**，因为两端的形态不同：
    /// iPhone 上是 push 一个详情页，Mac 上是开一个独立详情窗口
    /// （``ListingWindow``）——而那个窗口按 id 去重，所以「同一条链接点两次」
    /// 是激活已有窗口，正是风险 6 里「优先激活已显示该房源的窗口」那一条。
    ///
    /// **没登录时不丢掉**：风险 6 说「URL 与通知路由在未登录时暂存，认证后再执行」。
    /// 这里存进 `pendingDeepLink`，登录态一变就重放。
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "h2smonitor" else { return }
        guard auth.isAuthenticated else {
            pendingDeepLink = url
            return
        }
        let id = url.lastPathComponent
        guard !id.isEmpty else { return }
        switch url.host {
        case "listing":
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: FlatRadarMacApp.listingWindowID, value: id)
        case "map":
            // 地图那一路要有个浏览窗口才有地方落。没有就先开一个，
            // `openWindow(id:)` 对已开着的主窗口是"激活"，不会堆第二个。
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: FlatRadarMacApp.mainWindowID)
            NotificationCenter.default.post(name: .flatRadarLocateOnMap,
                                            object: nil,
                                            userInfo: ["listing_id": id])
        default:
            break
        }
    }

    /// 系统已经不会再弹权限框了，就由我们来说。
    ///
    /// 为什么只认 `.denied`：`.notDetermined` 时系统自己会弹（macOS 上是右上角
    /// 一条横幅），我们再弹一个就是两个框叠在一起。只有「问过、被拒、系统不会再问」
    /// 这一种情况，用户才完全不知道推送没开——`PushStore` 以前连这个状态都报不对，
    /// 见它 `requestPermissionAndRegister` 里 catch 分支的注释。
    private func offerNotificationSettingsIfBlocked() {
        // 用户自己关掉推送的，不提醒——他没开权限正是他要的结果。
        guard push.permissionStatus == .denied,
              !push.deliveryDisabledByUser,
              !didOfferNotificationSettings,
              !notificationsAlertSuppressed else { return }
        didOfferNotificationSettings = true
        showNotificationsOff = true
    }

    var body: some View {
        Group {
            // 恢复会话的那一小会儿**不能显示登录表单**——理由和那个弹出来的
            // 密码建议框见 ``AuthStore/isRestoringSession``。
            if auth.isRestoringSession {
                SessionRestorePane()
            } else if auth.isAuthenticated {
                MainWindow()
            } else {
                SignInPane()
            }
        }
        // 风险 6 第一条「登录恢复只执行一次」。
        //
        // 这个 flag 原先是**这个视图的** `@State`，而 `RootView` 是每个窗口一份——
        // ⌘N 开第二个窗口就会再恢复一次会话。移进 ``AppFeed`` 之后无论开几个窗口
        // 都只跑一遍，见 ``AppFeed/restoreSessionOnce(_:)``。
        .task {
            await feed.restoreOnce {
                // 401 / 403 → 自动登出。iOS 一直有这一条，Mac 端漏了：token 被
                // 服务器撤销、别的设备改了密码、会话到期之后，界面仍然显示登录着，
                // 之后每个操作都失败，而用户看不出为什么。
                //
                // 放在恢复**之前**：恢复本身的那次 `getMe` 401 由 `restoreSession`
                // 自己处理（那时 `isAuthenticated` 还是 false，监听里那道门会放过）。
                // 放进 `restoreOnce`，一个进程只装一次；`observeAuthFailures` 自己
                // 也是幂等的，两道保险。
                auth.observeAuthFailures()
                await auth.restoreSession()
            }
            // 截图模式的身份要**等恢复跑完再设**。顺序不能反：CI 上钥匙串是空的、
            // 恢复必然失败，反过来在本地这台机器是登录着的，先设身份会被随后
            // 恢复回来的会话盖掉，于是 `UI_TEST_SHOW_LOGIN` 那条拍出来是主界面。
            ScreenshotMode.applyIdentity(auth)
        }
        // 登录态一变就重新判断一次 SSE 该不该活着（登录进来要连，登出要断）。
        .task(id: auth.isAuthenticated) {
            feed.syncStream(auth: auth)
            // 登录之前暂存的那条链接，现在能执行了。
            if auth.isAuthenticated, let url = pendingDeepLink {
                pendingDeepLink = nil
                // 两种链接都可能被暂存，按 scheme 分派回各自那条路。
                if url.scheme == "h2smonitor" {
                    handleDeepLink(url)
                } else {
                    handleUniversalLink(url)
                }
            }
        }
        // 菜单栏常驻也是这个判断的输入之一：没窗口但常驻着的时候流要留着。
        .task(id: menuBarResident) { feed.menuBarResident = menuBarResident }
        // `h2smonitor://listing/<id>` —— 分享出去的链接、推送 payload 里的
        // `deep_link`，别人点了要能唤起这个 app。
        //
        // 以前 Mac 上**整条路都不通**：scheme 只注册在 iOS target 的 Info.plist 里
        // （现在两端共用那一份了），所以系统根本不知道该把这种链接交给谁。
        .onOpenURL { handleDeepLink($0) }
        // Universal Link：`https://<服务器>/l/<id>`。
        //
        // **和 `.onOpenURL` 是两条路**，不能只接一条：自定义 scheme 走
        // `onOpenURL`，而 https 的 Universal Link 走 `NSUserActivity`
        // （`NSUserActivityTypeBrowsingWeb`）。两端都要接，因为两种链接都在流通——
        // 分享出去的是 Universal Link，推送 payload 里的还是 `h2smonitor://`。
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL else { return }
            handleUniversalLink(url)
        }
        // 外观要在主窗口一出现就套上，不能等用户打开设置窗口才生效。
        .task(id: appearance) { AppearancePreference(rawValue: appearance)?.apply() }
        // 登录态一变就重新判断一次：冷启动恢复会话、登录、注册、从访客转正
        // 四条路都会把 `wantsPush` 翻成 true，这里一个地方全接住。iOS 那边是
        // 六个调用点各调一次，漏一个就是一条路没有推送。
        //
        // 用 `.task(id:)` 不用 `.onChange`：后者对**初始值**不触发，冷启动时
        // 如果恢复得够快、第一次求值就已经是 true，就一次都不跑。
        .task(id: wantsPush) {
            // setup 是幂等的。放在这里而不是上面那个 task：两个 `.task` 谁先跑
            // 没有保证，放一起就不用赌顺序。
            push.setup(bridge: pushBridge)
            guard wantsPush, !Self.isUnderXCTest else { return }
            await push.requestPermissionAndRegister()
            offerNotificationSettingsIfBlocked()
        }
        // 从系统设置切回来：之前被拦、现在可能已经打开了，重新注册一次。
        //
        // 只在**这次启动弹过窗**之后才做——那说明用户确实可能去改过。不加这道门，
        // 冷启动那一下的 didBecomeActive 也会触发，和上面的 task 并发注册两次。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            guard didOfferNotificationSettings, wantsPush,
                  push.permissionStatus == .denied else { return }
            Task { await push.requestPermissionAndRegister() }
        }
        .alert("Notifications Are Off", isPresented: $showNotificationsOff) {
            Button("Open System Settings") { openURL(NotificationPreferences.systemSettingsURL) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("FlatRadar can't alert you about new listings or status changes. Turn on notifications for FlatRadar in System Settings → Notifications.")
        }
        .dialogSuppressionToggle("Don't remind me again", isSuppressed: $notificationsAlertSuppressed)
        // 登录屏用小窗口，进主界面再放回去。
        //
        // 为什么要管：`WindowGroup` 的 `defaultSize` 是**场景级**的，按主窗口
        // 定的 1440×900——三栏表格需要那么宽。登录屏只有一栏说明加一个表单，
        // 摊在 1440×900 里表单会飘在正中央、四周大片空白，像没做完。
        //
        // 记住进来之前的尺寸再缩，出去时原样还回去：这样用户自己调过的窗口
        // 不会被登出一次就抹掉。冷启动时如果已经登录，这段一次都不跑。
        .background(WindowSizer(compact: !auth.isAuthenticated))
    }
}

/// 按登录态切窗口尺寸。见 ``RootView`` 里的调用点。
private struct WindowSizer: NSViewRepresentable {

    let compact: Bool

    /// 登录屏的尺寸，取自设计稿那张图的比例。
    static let signInSize = NSSize(width: 900, height: 620)

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // 下一个 runloop 再动：`updateNSView` 跑的时候视图不一定已经进了窗口。
        // 截图模式下尺寸由 ``ScreenshotMode`` 说了算，这里整段让路。
        //
        // **要重试，不能只 async 一次。** 只试一次时 `view.window` 常常还是 nil
        // （尤其是窗口走系统恢复那条路创建的时候），`pin` 于是一次都没跑，恢复
        // 回来的尺寸就这么留下了。实测连续启动五次：第一次 1440×900（重编译后
        // 没有恢复状态），之后 868 → 836 → 804 → 772，每次矮一条标题栏。
        //
        // 反复复位还有第二个作用：`pin` 之后仍有东西会改尺寸，多按几次能把它按住。
        if ScreenshotMode.isOn {
            for delay in [0.0, 0.1, 0.3, 0.6, 1.0, 1.5, 2.5, 4.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let window = view.window else { return }
                    ScreenshotMode.pin(window)
                }
            }
            return
        }
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let current = window.contentLayoutRect.size
            if compact {
                guard current != Self.signInSize else { return }
                context.coordinator.restoreTo = current      // 记住原来的
                window.setContentSize(Self.signInSize)
                window.center()
            } else if let target = context.coordinator.restoreTo {
                context.coordinator.restoreTo = nil
                window.setContentSize(target)
                window.center()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 记住登录前的窗口尺寸。放在 coordinator 里而不是 `@State`：
    /// 这个 representable 会随登录态重建，`@State` 活不过那一次重建。
    final class Coordinator { var restoreTo: NSSize? }
}

/// 应用菜单里的 Sign Out。
///
/// `auth` / `push` 是**显式传进来**的，不走 `@Environment`。
///
/// `.environment(auth)` 挂在 `WindowGroup` 里的 `RootView` 上，而 `commands { }`
/// 是 **Scene 级**的作用域，读不到窗口内容那一层注入的环境值——写成
/// `@Environment(AuthStore.self)` 会在菜单第一次求值时直接 trap
/// （"No Observable object of type AuthStore found"）。而 `FlatRadarMacApp`
/// 自己就攥着那个 `@State`，直接给过来就行。
private struct SignOutCommand: View {

    let auth: AuthStore
    let push: PushStore

    var body: some View {
        Button("Sign Out") {
            // 先解绑设备再登出，顺序的理由见 ``SessionActions``——设置页的
            // Sign Out 走的是同一个函数。
            // 账户数据（通知、未读、最新房源、桌面小组件）**不在这里清**：
            // `AuthStore.logout()` 会广播会话结束，``AppFeed`` 听着那一声统一清。
            // 原先这一条是唯一手动清的登出路径，设置页和删号那两条都漏了——
            // 见 ``AppFeed/init()``。
            Task { await SessionActions.signOut(auth: auth, push: push) }
        }
        // 访客态也给它：`enterAsGuest()` 同样把 `isAuthenticated` 置真，
        // 没有这一条的话「以访客进来」就成了单程票。
        .disabled(!auth.isAuthenticated)
    }
}

/// View 菜单里的四屏切换（⌘1 / ⌘2 / ⌘3 / ⌘4）。
///
/// 为什么 doc 里只写了 ⌘1/2/3，这里做了四个
/// -------------------------------------
/// Phase 4 那一条写的是「补充 ⌘1/2/3 切列表 / 地图 / 日历」，写的时候 Alerts
/// 还在 Phase 3 没做。现在侧栏是**四**个条目，只给前三个快捷键的话，第四个
/// 就成了唯一一个没有键盘入口的屏——那比四个都没有更难解释。
///
/// **作用于当前窗口**，不是全局：读的是 `@FocusedValue`，所以 ⌘2 切的是你正在
/// 看的那个窗口。两个窗口可以一个停在列表、一个停在地图，这也是
/// `BrowseModel.section` 一开始就放在窗口级的理由。
private struct SectionCommands: View {
    @FocusedValue(\.browseModel) private var model

    var body: some View {
        ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
            Button(section.label) { model?.section = section }
                // `KeyEquivalent` 要一个 `Character`。四屏对应 "1"…"4"。
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                .disabled(model == nil)
        }
    }
}

/// 侧栏和右栏的开关。
///
/// 为什么必须有这两条
/// ------------------
/// 它们此前**只存在于工具栏**：侧栏是 `NavigationSplitView` 自带的那个按钮，
/// 右栏是 `MainWindow` 自己补的。而工具栏在 Mac 上是可以隐藏的——藏了之后
/// 这两栏就没有任何入口能再打开，右栏连快捷键都没有。
///
/// docs/MACOS.md 引的那条规矩说得更直接：**每个工具栏项都必须同时是一条菜单
/// 命令**，因为工具栏可以被自定义、可以被隐藏。反过来不成立。
private struct PaneCommands: View {
    @FocusedValue(\.inspectorVisible) private var inspector

    var body: some View {
        // 侧栏走响应链，不自己存状态。
        //
        // `MainWindow` 那边**故意没有** `columnVisibility:` 绑定（理由写在那里：
        // 绑了之后每次开合都重算整个 body，右栏的右对齐数值会跟着做位移动画，
        // 逐帧量过 `€1766` 左跳 30pt）。所以这里不能读那个状态，只能把动作
        // 发给系统自己的 `toggleSidebar(_:)`——和工具栏那个按钮走的是同一条路，
        // 行为天然一致。
        //
        // 代价是标题只能是静态的 `Toggle Sidebar`，不是随状态变的
        // Show / Hide。拿不到状态就别假装拿得到。
        Button("Toggle Sidebar") {
            NSApp.keyWindow?.firstResponder?.tryToPerform(
                #selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
        }
        .keyboardShortcut("s", modifiers: [.control, .command])

        // 右栏这边有 binding，标题就跟着状态走。⌥⌘I 是 Finder 的「显示简介 /
        // 检查器」那个键位，Mac 用户手上是熟的。
        Button(inspector?.wrappedValue == false ? "Show Inspector" : "Hide Inspector") {
            inspector?.wrappedValue.toggle()
        }
        .keyboardShortcut("i", modifiers: [.option, .command])
        .disabled(inspector == nil)
    }
}

/// 菜单命令。放在单独的 `Commands` 里才拿得到 `@FocusedValue`。
private struct BrowseCommands: View {
    @FocusedValue(\.browseModel) private var model

    var body: some View {
        Button("Reload Listings") { Task { await model?.reload() } }
            .keyboardShortcut("r")
            .disabled(model == nil)
        Button("Filter…") { model?.requestSearchFocus() }
            .keyboardShortcut("f")
            .disabled(model == nil)
    }
}

/// 「Listing」菜单：上下浏览 + 对当前这条的动作。
///
/// 表格自己有焦点时 ↑↓ 本来就能翻（底下是 NSTableView），为什么还要菜单项：
///
/// 1. **可发现**。Mac 用户是从菜单里学会快捷键的，没有菜单项的快捷键等于不存在。
/// 2. **焦点不在表格上时也能翻**。焦点在 inspector 里、或者刚点完工具栏按钮，
///    这时候裸 ↑↓ 不归表格管，⌘↑/⌘↓ 仍然有效。
///
/// 完成判据里那条「能只用键盘筛选、跨页浏览并固定两套房源比较」，缺的就是
/// 「固定」这一步没有键盘入口——⌘D 补上了。
private struct ListingCommands: View {
    @FocusedValue(\.browseModel) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Next Listing") { model?.moveSelection(by: 1) }
            .keyboardShortcut(.downArrow, modifiers: .command)
        Button("Previous Listing") { model?.moveSelection(by: -1) }
            .keyboardShortcut(.upArrow, modifiers: .command)

        Divider()

        // Phase 4 的完成判据里有「悬停操作均有**键盘或菜单等价入口**」。
        // 表格行悬停出来的那三个按钮、右键菜单里的「Open in New Window」，
        // 等价入口就是这一条——双击和拖出去都不是键盘能做的事。
        Button("Open in New Window") {
            guard let id = model?.focused else { return }
            openWindow(id: FlatRadarMacApp.listingWindowID, value: id)
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(model?.focused == nil)

        // 「在地图上定位」在右键菜单里有，这里是它的**菜单 / 键盘等价入口**。
        // 完成判据那条「悬停操作均有键盘或菜单等价入口」管的是悬停，但右键菜单
        // 同样是鼠标专属的——一个只能用右键触发的功能在 Mac 上也是半个功能。
        Button("Show on Map") {
            guard let model, let l = model.listing(model.focused) else { return }
            model.locateOnMap(l)
        }
        .keyboardShortcut("l")
        .disabled(model?.focused == nil)

        Divider()

        Button(pinTitle) { if let id = model?.focused { model?.togglePin(id) } }
            .keyboardShortcut("d")
            .disabled(model?.focused == nil)
        Button("Open on Platform") { openFocused() }
            .keyboardShortcut("o")
            .disabled(model?.focused == nil)
        Button("Copy Link") { copyFocused() }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model?.focused == nil)
        // 分享的菜单入口。右键菜单和右栏都有按钮，这里是键盘 / 菜单那一份——
        // 和 Phase 4 那条「鼠标专属的功能在 Mac 上是半个功能」同一个道理。
        //
        // 分享不了时它自己会画成一条灰的，不会整条消失（见 ``ListingShareMenuItem``）。
        ListingShareMenuItem(listing: model?.listing(model?.focused))
    }

    private var pinTitle: String {
        guard let model, let id = model.focused else { return "Pin for Comparison" }
        return model.pinned.contains(id) ? "Unpin" : "Pin for Comparison"
    }

    private func openFocused() {
        guard let l = model?.listing(model?.focused), let url = URL(string: l.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyFocused() {
        guard let l = model?.listing(model?.focused) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(l.url, forType: .string)
    }
}
