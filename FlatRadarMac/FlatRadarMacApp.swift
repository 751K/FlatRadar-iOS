import SwiftUI
import AppKit
import FlatRadarCore

/// macOS 客户端入口。
///
/// 应用级状态只有 ``AuthStore``（服务器 / 账户 / 认证），窗口级的一切在
/// ``BrowseModel`` 里——docs/MACOS.md 风险 6 的划分。带查询状态的
/// `ListingsStore` 不做全局单例，否则将来两个窗口会互相覆盖排序和筛选。
///
/// 刻意**不做**的：推送（不申请权限、不注册 token、不调 `/devices/register`）、
/// 多窗口、地图 / 日历。都在文档里排在后面。
@main
struct FlatRadarMacApp: App {

    @State private var auth = AuthStore()

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
            RootView()
                .environment(auth)
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
            CommandGroup(after: .appSettings) {
                Divider()
                SignOutCommand(auth: auth)
            }
            CommandMenu("Listing") {
                ListingCommands()
            }
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
    @State private var didRestore = false

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
/// `auth` 是**显式传进来**的，不走 `@Environment`。
///
/// `.environment(auth)` 挂在 `WindowGroup` 里的 `RootView` 上，而 `commands { }`
/// 是 **Scene 级**的作用域，读不到窗口内容那一层注入的环境值——写成
/// `@Environment(AuthStore.self)` 会在菜单第一次求值时直接 trap
/// （"No Observable object of type AuthStore found"）。而 `FlatRadarMacApp`
/// 自己就攥着那个 `@State`，直接给过来就行。
private struct SignOutCommand: View {

    let auth: AuthStore

    var body: some View {
        Button("Sign Out") {
            Task { await auth.logout() }
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
