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
    /// 通知筛选的保存状态。只有设置页用，但放应用级：设置窗口和主窗口是两个场景，
    /// 放进任何一个窗口里，另一个都拿不到。
    @State private var filterStore = MeFilterStore()

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
        WindowGroup("FlatRadar") {
            RootView(pushBridge: pushDelegate)
                .environment(auth)
                .environment(push)
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
            CommandMenu("Listing") {
                ListingCommands()
            }
        }

        // ⌘,。`Settings` 是独立场景，`WindowGroup` 里注入的环境值到不了这里，
        // 要再注入一遍。
        Settings {
            SettingsView()
                .environment(auth)
                .environment(push)
                .environment(filterStore)
        }
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
private struct RootView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(PushStore.self) private var push
    @Environment(\.openURL) private var openURL
    @State private var didRestore = false

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

    /// 这一刻该不该有推送注册。
    ///
    /// 访客没有 bearer，`/devices/register` 调不通；登出后也不该再注册；用户在设置里
    /// 关了「推送到这台 Mac」也不注册——不看这一条的话，关掉之后下次启动又被自动
    /// 注册回来（iOS 现在就是这样，见 ``NotificationPreferences/deliveryDisabledKey``）。
    private var wantsPush: Bool { auth.isAuthenticated && !auth.isGuest && !deliveryDisabled }

    @AppStorage(NotificationPreferences.deliveryDisabledKey) private var deliveryDisabled = false
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system.rawValue

    /// 跑在 XCTest 的宿主进程里。
    ///
    /// `FlatRadarMacTests` 的 `TEST_HOST` 就是这个 app，跑单测会真的启动它、
    /// 真的从钥匙串恢复会话——这台开发机是登录着的，不拦的话**每跑一次单测**
    /// 就会弹一次通知权限框、往后端注册一台设备。
    private static let isUnderXCTest =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// 系统已经不会再弹权限框了，就由我们来说。
    ///
    /// 为什么只认 `.denied`：`.notDetermined` 时系统自己会弹（macOS 上是右上角
    /// 一条横幅），我们再弹一个就是两个框叠在一起。只有「问过、被拒、系统不会再问」
    /// 这一种情况，用户才完全不知道推送没开——`PushStore` 以前连这个状态都报不对，
    /// 见它 `requestPermissionAndRegister` 里 catch 分支的注释。
    private func offerNotificationSettingsIfBlocked() {
        guard push.permissionStatus == .denied,
              !didOfferNotificationSettings,
              !notificationsAlertSuppressed else { return }
        didOfferNotificationSettings = true
        showNotificationsOff = true
    }

    var body: some View {
        Group {
            if auth.isAuthenticated {
                MainWindow()
            } else {
                SignInPane()
            }
        }
        .task {
            guard !didRestore else { return }
            didRestore = true
            await auth.restoreSession()
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
            Task { await SessionActions.signOut(auth: auth, push: push) }
        }
        // 访客态也给它：`enterAsGuest()` 同样把 `isAuthenticated` 置真，
        // 没有这一条的话「以访客进来」就成了单程票。
        .disabled(!auth.isAuthenticated)
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

    var body: some View {
        Button("Next Listing") { model?.moveSelection(by: 1) }
            .keyboardShortcut(.downArrow, modifiers: .command)
        Button("Previous Listing") { model?.moveSelection(by: -1) }
            .keyboardShortcut(.upArrow, modifiers: .command)

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
