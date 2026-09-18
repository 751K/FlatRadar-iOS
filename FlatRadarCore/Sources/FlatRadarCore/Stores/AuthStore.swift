import Foundation
import Network
import SwiftUI

public enum Role: String, Sendable {
    case guest
    case user
    case admin
}

/// 登录 / 注册请求里的设备名。
///
/// 曾经是 `#if os(iOS)` → `UIDevice.current.name`，`#else` → `Host.current().name`。
/// 后者会把系统主机名（常含用户姓名）发进请求体，是 Mac 端首次登录前必须堵掉的
/// 隐私坑，见 docs/MACOS.md 风险 4。现在由宿主 app 注入，Core 不再猜。
enum DeviceName {
    static var current: String { PlatformEnvironment.info.deviceName }
}

@MainActor
@Observable
public final class AuthStore {

    /// 隐式 init 随 `public` 一起变成 internal，宿主 app 构造不了。
    ///
    /// 这里**不是**空实现：`isRestoringSession` 必须在第一帧之前就定好，
    /// 理由见那个属性。
    public init() {
        isRestoringSession = Self.hasPersistedSession(server: server)
    }

    public var isAuthenticated = false

    /// 启动时的会话恢复还没跑完——**界面这段时间不该显示登录表单**。
    ///
    /// 要解决什么
    /// ----------
    /// 宿主那句 `if auth.isAuthenticated { 主界面 } else { 登录页 }` 里，
    /// `isAuthenticated` 一开始是 false，而 ``restoreSession()`` 挂在 `.task`
    /// 上、里面还要等一次 `getMe()` 网络往返。SwiftUI 先求值 `body` 再跑
    /// `.task`，所以**冷启动必定先渲染一次登录页**，持续一整个网络往返。
    ///
    /// 在 Mac 上这不只是"闪一下"：登录页里那个 `.textContentType(.password)`
    /// 的输入框会成为新窗口的初始第一响应者，macOS 于是弹出「密码」自动填充
    /// 建议。等主界面换上来时，那个弹窗是**独立的系统窗口**，不会跟着消失——
    /// 表现就是"自动登录进去了，房源列表上却浮着一个选密码的框"。
    ///
    /// 为什么在 `init` 里定，而不是让它从 false 开始
    /// -----------------------------------------
    /// 从 false 开始的话，第一帧仍然是登录页，只是短一点——而弹出自动填充
    /// 只需要那一帧。所以在构造时就同步问一句「钥匙串里有没有 token」：
    /// 有就说明马上会有一次恢复，先按"恢复中"渲染；没有就直接是登录页，
    /// 那种情况下弹自动填充**正是应该的**。
    ///
    /// 读的是普通的 token 条目，不带访问控制，不会弹系统认证框——那条受保护的
    /// 生物识别凭据由 ``BiometricAuthService`` 管，两回事。
    public private(set) var isRestoringSession = false
    public var role: Role = .guest
    public var userInfo: UserInfo?
    public var isLoading = false
    public var errorMessage: String?
    public var lastError: APIError?

    /// 登录成功后待保存的 Face ID 凭据——由 LoginView 设置，ContentView 弹出 alert。
    /// LoginView 会在登录成功后立即被 ContentView 替换掉，alert 放 LoginView
    /// 层级会来不及弹出。提到这里让 ContentView 处理。
    public var pendingBiometricCredential: (username: String, password: String, role: String)?

    /// 上一次登录 / 注册后，bearer token 有没有**真的**落进钥匙串。
    ///
    /// iOS 上写失败会静默回退到 `UserDefaults`——bearer token 明文躺在沙盒里，
    /// 而用户以为它在钥匙串。这个既有行为这一版不动（线上有真实用户，改它要
    /// 单独验证），但 **Mac 路径不继承**：写失败就是 `false`，且不写回退，
    /// 由宿主 app 决定怎么告诉用户。见 docs/MACOS.md 风险 2。
    ///
    /// 名字说的就是字面意思：iOS 回退成功时会话确实持久化了，但**不在钥匙串**，
    /// 所以这里同样是 `false`。目前只有 Mac 端读它。
    public private(set) var sessionSavedToKeychain = true

    private let client = APIClient.shared
    private var server: String {
        UserDefaults.standard.string(forKey: "server_url") ?? APIClient.defaultServerHost
    }

    /// 会话结束了：登出、删号成功、或者 401 自动登出（它走的也是 ``logout()``）。
    ///
    /// 为什么要有这个广播
    /// ------------------
    /// 会话结束时要清掉的不只是这里的状态——宿主 app 还攥着通知、未读数、最新房源、
    /// 桌面小组件，全是**上一个账号的数据**。原先靠每个调用点自己记得去清，结果 Mac
    /// 上三条登出路径只有一条清了：设置页的 Sign Out、Delete Account 都没清，
    /// 退出后进游客模式还能看到上一个账号的通知；401 自动登出那条更是连接都没接。
    ///
    /// 改成**这里**广播：会话在哪儿结束都从这两处出去（``logout()`` 和
    /// ``deleteAccount()`` 成功那一支），宿主只要听一次，不用知道是谁发起的。
    public static let sessionEndedNotification = Notification.Name("AuthStore.sessionEnded")

    @ObservationIgnored private var authFailureObserver: (any NSObjectProtocol)?

    /// Listen for global auth failures from any API call and auto-logout.
    ///
    /// **幂等**：装第二次什么都不做。装两个的话一次 401 会登出两遍——而 Mac 上
    /// 调它的地方挂在窗口的 `.task` 里，哪一层保证"只跑一次"都不该靠调用方记得。
    public func observeAuthFailures() {
        guard authFailureObserver == nil else { return }
        authFailureObserver = NotificationCenter.default.addObserver(
            forName: APIClient.authFailedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isAuthenticated, !self.isGuest else { return }
                await self.logout()
            }
        }
    }

    // MARK: - Restore Session

    /// 钥匙串（或旧的 UserDefaults 回退位）里有没有一份可以恢复的会话。
    ///
    /// 判据和 ``restoreSession()`` 取 token 的那两行**必须一致**：这边说有、
    /// 那边取不到的话，界面会停在"恢复中"等一个永远不会发生的结果。
    /// `AuthStoreRestoreTests` 守着这一条。
    static func hasPersistedSession(server: String) -> Bool {
        KeychainManager.load(server: server) != nil
            || UserDefaults.standard.string(forKey: "auth_token") != nil
    }

    public func restoreSession() async {
        // 不管从哪条路返回，"恢复中"都要落下：提前 return 的那两条同样算数，
        // 否则界面永远停在占位屏上。
        defer { isRestoringSession = false }

        // 截图测试：要求 LoginView 时跳过恢复，否则 keychain 残留的 token
        // 会让 ContentView 直接展示 Dashboard。生产 build 永远不会进这个分支。
        if UITestFlags.isOn("UI_TEST_SHOW_LOGIN") {
            return
        }

        let savedToken = KeychainManager.load(server: server)
            ?? UserDefaults.standard.string(forKey: "auth_token")
        guard let token = savedToken else {
            stopRestoreRetries()
            return
        }

        // 这一轮恢复的"代号"。等 `getMe()` 的这段时间里用户可能已经手动登录、
        // 进了游客、或者登出——那之后回来的结果属于一个已经不存在的会话，
        // 不能再碰 client 的 token 或登录态（见 ``abandonPendingRestore()``）。
        let generation = restoreGeneration
        client.setToken(token)

        do {
            let me = try await client.getMe()
            guard generation == restoreGeneration else { return }
            stopRestoreRetries()
            applyMe(me)
        } catch {
            guard generation == restoreGeneration else { return }
            client.setToken(nil)
            if Self.shouldDiscardSession(after: error) {
                // 服务器明确说这个 token 不认了（过期 / 被撤销 / 账号没了）。
                KeychainManager.delete(server: server)
                UserDefaults.standard.removeObject(forKey: "auth_token")
                stopRestoreRetries()
            } else {
                // 没问到，不等于被拒。token 留在钥匙串里，停在登录页并告诉用户，
                // 网络回来 / 退避时间到了再问一次。理由见 ``shouldDiscardSession(after:)``。
                sessionRestorePending = true
                scheduleRestoreRetry()
            }
        }
    }

    // MARK: - 恢复没能验证时

    /// 钥匙串里有一份会话，但这次**没能向服务器验证**它——连不上、超时、服务器出错。
    ///
    /// 界面据此停在登录页上说一句「暂时连不上，你仍是登录状态」，而不是一张
    /// 什么都没说的登录表单。为什么不停在「恢复中」那一屏：离线可能持续很久，
    /// 那一屏什么都做不了，而登录页上至少还能换个账号或以游客进去。
    ///
    /// 为什么不干脆当作已登录进主界面：本地**只存了 token**，角色、用户名、
    /// 筛选条件全靠 `getMe()` 才知道。不知道是普通用户还是管理员，主界面就画不对。
    public private(set) var sessionRestorePending = false

    /// 手动重试正在进行。登录页那个 Try Again 据此转圈、防连点。
    public private(set) var isRetryingRestore = false

    /// 这次恢复失败，**该不该把存着的会话扔掉**。
    ///
    /// 原先的问题
    /// ----------
    /// `catch` 里不分青红皂白删 token，注释写着「Token expired or revoked」。可 catch
    /// 抓到的远不止这一种：断网、DNS 失败、超时、后端部署那几十秒的 5xx、限流 429，
    /// 全都走这一支。token 明明有效，只是这一次没问到，就被永久删掉——没网时打开
    /// app 等于被登出，网络回来也回不去，只能重新输密码，而且不知道为什么。
    ///
    /// 判据：只认**服务器自己在响应信封里说**的 `unauthorized` / `forbidden`
    /// ——和 `APIClient` 触发全局 `authFailedNotification`（401 自动登出）用的是
    /// **同一个谓词** ``APIError/isAuthError``。「这个会话死了」这件事只有后端说了算，
    /// 两处各判一遍迟早会判得不一样。
    ///
    /// 由此推出的几种情况：
    /// - `.network`：没连上，token 可能完全有效 → 保留
    /// - `.serverError` / `.rateLimited` / `.badResponse`：服务器那边的事 → 保留
    /// - `.decoding`：响应不是我们的 JSON 信封——典型是后端重启时反向代理吐的
    ///   HTML 502 页 → 保留
    /// - `CancellationError` 等非 `APIError`：请求被取消（比如恢复途中窗口关了）→ 保留
    ///
    /// 代价：如果哪天某个代理层直接回一个**不带信封**的 401，这里会把一个真失效的
    /// token 留下来、隔一段时间问一次。那是可恢复的（手动登录就覆盖掉了）；
    /// 反过来错删一个有效 token 是不可恢复的——两个错误方向里选了能回头的那个。
    static func shouldDiscardSession(after error: Error) -> Bool {
        (error as? APIError)?.isAuthError ?? false
    }

    /// 第 `attempt` 次自动重试之前等多久：3s、10s、30s，之后每 60s 一次。
    ///
    /// 退避是为了后端出故障的时候别一起去敲它；封顶 60s 是因为 app 开着、停在
    /// 登录页上的人，等一分钟以上还没进去就会自己去输密码了，再往后拉长没有意义。
    nonisolated static func restoreRetryDelay(attempt: Int) -> Duration {
        let schedule: [Duration] = [.seconds(3), .seconds(10), .seconds(30)]
        return attempt < schedule.count ? schedule[attempt] : .seconds(60)
    }

    /// 网络状态变了，**要不要马上重试**：只认「从断到通」这一下。
    ///
    /// `NWPathMonitor` 开始监听时会先回调一次当前状态。如果这次失败不是断网而是
    /// 后端 5xx，那一刻网络本来就是通的——把"通"当成信号立刻重试，就会在后端还
    /// 没恢复时白打一轮，然后再开监听、再立刻回调"通"、再打……变成一个死循环。
    /// 所以 `previous == nil`（第一次回调）不算数，那种情况交给退避计时器。
    nonisolated static func shouldRetryOnPathChange(from previous: Bool?, to current: Bool) -> Bool {
        previous == false && current
    }

    /// 手动再试一次（登录页上那个 Try Again），也是自动重试走的同一条路。
    public func retryPendingRestore() async {
        guard sessionRestorePending, !isAuthenticated, !isRetryingRestore else { return }
        isRetryingRestore = true
        defer { isRetryingRestore = false }
        await restoreSession()
    }

    @ObservationIgnored private var restoreGeneration = 0
    @ObservationIgnored private var restoreRetryAttempt = 0
    @ObservationIgnored private var restoreRetryTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSatisfied: Bool?

    private func scheduleRestoreRetry() {
        restoreRetryTask?.cancel()
        let delay = Self.restoreRetryDelay(attempt: restoreRetryAttempt)
        restoreRetryAttempt += 1
        restoreRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.retryPendingRestore()
        }
        watchNetwork()
    }

    /// 网络一通就重试，不必干等退避计时器——离线启动那种情况下，这才是用户
    /// 真正会遇到的恢复路径（下地铁、Wi-Fi 连上）。
    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        // ⚠️ `@Sendable` 不能省。这个包开着默认 MainActor 隔离，不标的话这个闭包
        // 会被推断成 MainActor 隔离，而 `NWPathMonitor` 在它自己的队列上调它——
        // 隔离检查当场 trap。2.1.0 线上那次无限崩溃就是同一类问题
        // （后台回调的闭包没写 nonisolated）。
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkPathChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "AuthStore.path"))
        pathMonitor = monitor
    }

    private func networkPathChanged(satisfied: Bool) {
        let previous = lastPathSatisfied
        lastPathSatisfied = satisfied
        guard sessionRestorePending,
              Self.shouldRetryOnPathChange(from: previous, to: satisfied) else { return }
        restoreRetryAttempt = 0
        Task { await retryPendingRestore() }
    }

    /// 不再等了：恢复成功、被服务器拒绝、或者钥匙串里已经没有 token。
    private func stopRestoreRetries() {
        sessionRestorePending = false
        restoreRetryTask?.cancel()
        restoreRetryTask = nil
        restoreRetryAttempt = 0
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSatisfied = nil
    }

    /// 用户自己做了决定（手动登录 / 注册 / 进游客 / 登出）：挂着的那次恢复作废。
    ///
    /// 光停计时器不够——一次重试可能**正在等 `getMe()`**。它回来时要是还照常
    /// `client.setToken(nil)`，就把用户刚手动登录拿到的新 token 抹掉了；要是成功，
    /// 又会用旧账号的 `me` 盖掉新账号。代号一变，那次回来的结果就直接丢弃。
    private func abandonPendingRestore() {
        restoreGeneration &+= 1
        stopRestoreRetries()
    }

    // MARK: - Login

    public func loginAsAdmin(password: String, ttlDays: Int = 90) async {
        await login(username: "__admin__", password: password, ttlDays: ttlDays)
    }

    public func loginAsUser(name: String, password: String, ttlDays: Int = 90) async {
        await login(username: name, password: password, ttlDays: ttlDays)
    }

    private func login(username: String, password: String, ttlDays: Int) async {
        abandonPendingRestore()
        isLoading = true
        errorMessage = nil
        do {
            let device = DeviceName.current
            let resp = try await client.login(
                username: username, password: password,
                deviceName: device, ttlDays: ttlDays)
            client.setToken(resp.token)
            persist(token: resp.token)

            let me = try await client.getMe()
            applyMe(me)
        } catch {
            #if DEBUG
            print("[AuthStore] login error: \(error)")
            #endif
            recordError(error)
        }
        isLoading = false
    }

    // MARK: - Register

    public func register(name: String, password: String, ttlDays: Int = 90) async {
        abandonPendingRestore()
        isLoading = true
        errorMessage = nil
        do {
            let device = DeviceName.current
            let resp = try await client.register(
                username: name, password: password,
                deviceName: device, ttlDays: ttlDays)
            client.setToken(resp.token)
            persist(token: resp.token)
            let me = try await client.getMe()
            applyMe(me)
        } catch {
            #if DEBUG
            print("[AuthStore] register error: \(error)")
            #endif
            recordError(error)
        }
        isLoading = false
    }

    /// 统一错误收纳：errorMessage 优先取后端给的具体原因（failureReason），
    /// fallback 到 LocalizedError 的标题（errorDescription / localizedDescription）。
    ///
    /// 旧实现只取 localizedDescription，导致：
    /// - 后端返回 409 conflict "该用户名已被注册" → UI 显示 "Server Error"
    /// - 后端返回 401 "用户名或密码错误" → UI 显示 "Login Failed"
    ///
    /// 现在错误条 = 后端给的人话 message，登录/注册失败用户能立即知道为什么。
    private func recordError(_ error: Error) {
        // 被取消不是失败——见 Error.isCancellation。登录 / 注册 / 改密 / 注销
        // 五处 catch 都汇到这里，拦在这一处就够。
        guard !error.isCancellation else { return }
        let api = error as? APIError
        lastError = api
        errorMessage = api?.failureReason ?? error.localizedDescription
    }

    // MARK: - Guest

    public func enterAsGuest() {
        abandonPendingRestore()
        role = .guest
        isAuthenticated = true
        userInfo = nil
        pendingBiometricCredential = nil
    }

    /// 编辑 filter 保存后调用——把 ``userInfo.listingFilter`` 同步成后端
    /// 规范化过的版本。Dashboard.meSummary 等读 userInfo 的视图会即时刷新。
    public func updateLocalFilter(_ filter: ListingFilter) {
        guard var info = userInfo else { return }
        info.listingFilter = filter
        userInfo = info
    }

    /// 保存 bearer token，并记录它到底进没进钥匙串。
    ///
    /// 平台分歧在这一处收口，不散进 login / register 两个调用点——它们原先各写
    /// 了一遍同样的 do/catch，改一处漏一处是迟早的事。
    private func persist(token: String) {
        do {
            try KeychainManager.save(token: token, server: server)
            sessionSavedToKeychain = true
            // 钥匙串成功之后清掉回退副本。
            //
            // 在 2026-09-09 修好 `KeychainManager` 的非法属性之前，iOS 上**每一次**
            // 保存都失败、每一次都落到这个回退，所以现有用户的沙盒里都有一份明文
            // bearer token。不清的话它会一直留着——`restoreSession` 优先读钥匙串，
            // 那份副本从此永远用不上，却永远在。
            UserDefaults.standard.removeObject(forKey: "auth_token")
        } catch {
            sessionSavedToKeychain = false
            #if DEBUG
            // 不打 token，只打失败这件事。凭据不进日志。
            print("[AuthStore] Keychain save failed: \(error.localizedDescription)")
            #endif
            #if os(iOS)
            // iOS 既有行为，原样保留：宁可明文存也不让用户每次重开都重登。
            UserDefaults.standard.set(token, forKey: "auth_token")
            #endif
        }
    }

    // MARK: - Logout

    public func logout() async {
        abandonPendingRestore()
        _ = try? await client.logout()
        pendingBiometricCredential = nil
        KeychainManager.delete(server: server)
        UserDefaults.standard.removeObject(forKey: "auth_token")
        client.setToken(nil)
        sessionSavedToKeychain = true
        role = .guest
        isAuthenticated = false
        userInfo = nil
        errorMessage = nil
        NotificationCenter.default.post(name: Self.sessionEndedNotification, object: self)
    }

    // MARK: - Delete Account

    // MARK: - Change Password

    /// 修改当前 user 密码。
    ///
    /// 成功 → 返回 true，并把 errorMessage 清空；调用方负责 UI dismiss。
    /// 失败 → 返回 false，errorMessage 含后端 message。
    ///
    /// 调用前应先在 UI 层校验：
    /// - 两次新密码一致
    /// - 新密码 ≥ 4 字符
    /// - 新密码 != 当前密码（也可放给后端，会返 validation 错误）
    ///
    /// 副作用：后端会撤销该 user 名下"除当前 token 外"的所有 session。
    /// 当前设备保持登录态。
    /// 确认密码，用于设置页开启 Face ID。
    ///
    /// 返回 `false` 只表示"这次没通过"——密码错、网络断、服务端故障都归到
    /// 这里，具体原因写进 ``errorMessage``。调用方**不能**把 false 当成
    /// "密码错误"直接展示，否则断网时会告诉用户密码打错了。
    public func verifyPassword(_ password: String) async -> Bool {
        guard role == .user else {
            errorMessage = String(localized: "Only user accounts can do this.", bundle: .module)
            return false
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            return try await client.verifyPassword(password).ok
        } catch {
            #if DEBUG
            print("[AuthStore] verifyPassword error: \(error)")
            #endif
            recordError(error)
            return false
        }
    }

    public func changePassword(current: String, new: String) async -> Bool {
        guard role == .user else {
            errorMessage = String(localized: "Only user accounts can change password here.", bundle: .module)
            return false
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await client.changePassword(current: current, new: new)
            return true
        } catch {
            #if DEBUG
            print("[AuthStore] changePassword error: \(error)")
            #endif
            recordError(error)
            return false
        }
    }

    public func deleteAccount() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await client.deleteAccount()
            // Clear local state and return to login
            KeychainManager.delete(server: server)
            UserDefaults.standard.removeObject(forKey: "auth_token")
            client.setToken(nil)
            role = .guest
            isAuthenticated = false
            userInfo = nil
            NotificationCenter.default.post(name: Self.sessionEndedNotification, object: self)
        } catch {
            #if DEBUG
            print("[AuthStore] deleteAccount error: \(error)")
            #endif
            recordError(error)
        }
    }

    // MARK: - Private

    private func applyMe(_ me: MeResponse) {
        isAuthenticated = true
        role = Role(rawValue: me.role) ?? .guest
        userInfo = me.user
    }

    public var isAdmin: Bool { role == .admin }
    public var isUser: Bool { role == .user }
    public var isGuest: Bool { role == .guest }
}
