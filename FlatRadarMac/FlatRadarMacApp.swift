import SwiftUI
import FlatRadarCore

/// macOS 客户端入口（Phase 1）。
///
/// 这一版是**探针**，不是产品：一个窗口，登录 → 拉一页房源 → 报数量，外加
/// 钥匙串自检。目标不是好看，是把 docs/MACOS.md Phase 1 的完成判据一条条
/// 变成屏幕上能看见的东西。真正的表格 / 键盘浏览是 Phase 2。
///
/// 刻意**不做**的：推送（不申请权限、不注册 token、不调 `/devices/register`）、
/// 游客入口、多窗口状态归属。都在文档里排在后面。
@main
struct FlatRadarMacApp: App {

    @State private var auth = AuthStore()
    @State private var listings = ListingsStore()

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
            ProbeWindow()
                .environment(auth)
                .environment(listings)
        }
        .defaultSize(width: 560, height: 640)
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

private struct ProbeWindow: View {
    @Environment(AuthStore.self) private var auth
    @Environment(ListingsStore.self) private var listings

    @State private var username = ""
    @State private var password = ""
    @State private var selfTest: KeychainSelfTest?
    @State private var didRestore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                if auth.isAuthenticated {
                    signedIn
                } else {
                    signInForm
                }
                Divider()
                keychainPanel
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            guard !didRestore else { return }
            didRestore = true
            await auth.restoreSession()
            if auth.isAuthenticated { await listings.fetch() }
        }
    }

    // MARK: 标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FlatRadar for Mac").font(.largeTitle.weight(.semibold))
            Text("Phase 1 探针 · \(APIClient.defaultServerHost)")
                .font(.callout).foregroundStyle(.secondary)
            Text(AppVersion.displayName)
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: 未登录

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign In").font(.headline)
            // 凭据只在内存里，既不写进源码也不进日志。
            TextField("Username", text: $username)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .onSubmit { signIn() }
            HStack {
                Button("Sign In", action: signIn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(auth.isLoading || username.isEmpty || password.isEmpty)
                if auth.isLoading { ProgressView().controlSize(.small) }
            }
            errorBox
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 360, alignment: .leading)
    }

    // MARK: 已登录

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Signed in as", value: auth.userInfo?.name ?? "—")
            LabeledContent("Role", value: String(describing: auth.role))

            // 完成判据：「能从 flatradar.app 登录并显示房源数量」
            LabeledContent("Listings") {
                if listings.isLoading {
                    ProgressView().controlSize(.small)
                } else if listings.errorMessage != nil {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    Text("\(listings.listings.count) / \(listings.total)")
                        .monospacedDigit()
                }
            }

            if let err = listings.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }

            HStack {
                Button("Reload listings") { Task { await listings.refresh() } }
                Button("Sign Out") {
                    Task {
                        await auth.logout()
                        listings.clear()
                        selfTest = nil
                    }
                }
            }
            errorBox
        }
    }

    @ViewBuilder
    private var errorBox: some View {
        if let msg = auth.errorMessage {
            // 完成判据：「拒绝网络或凭据错误时，窗口显示可理解的错误」。
            // 用后端给的具体原因，不是「登录失败」四个字。
            VStack(alignment: .leading, spacing: 2) {
                Text(auth.lastError?.errorDescription ?? "Sign-in failed")
                    .font(.callout.weight(.medium))
                Text(msg).font(.caption)
            }
            .foregroundStyle(.red)
        }
    }

    // MARK: 钥匙串

    private var keychainPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keychain").font(.headline)

            // 会话到底进没进钥匙串。登录成功 ≠ 钥匙串成功。
            LabeledContent("Session stored in keychain") {
                statusText(auth.sessionSavedToKeychain)
            }
            // 完成判据：「确认没有触发 UserDefaults token 回退」
            LabeledContent("UserDefaults fallback token") {
                statusText(!KeychainDiagnostics.hasUserDefaultsFallbackToken,
                           ok: "none", bad: "present")
            }

            Button("Run keychain self-test") { selfTest = KeychainDiagnostics.run() }

            if let t = selfTest {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(t.steps.enumerated()), id: \.offset) { _, step in
                        Text(step).font(.callout.monospaced())
                    }
                    Text(t.allPassed ? "增 / 查 / 删 三步都通过" : "有步骤失败，见上")
                        .font(.caption)
                        .foregroundStyle(t.allPassed ? .green : .red)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func statusText(_ ok: Bool, ok okText: String = "yes",
                            bad: String = "no") -> some View {
        Text(ok ? okText : bad)
            .foregroundStyle(ok ? .green : .red)
    }

    private func signIn() {
        Task {
            await auth.loginAsUser(name: username, password: password)
            password = ""                       // 不在内存里多留一秒
            if auth.isAuthenticated { await listings.fetch() }
        }
    }
}
