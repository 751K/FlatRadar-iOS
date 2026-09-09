import Foundation
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
    /// 这些 store 的属性全有默认值，空实现与迁移前的隐式构造等价。
    public init() {}
    public var isAuthenticated = false
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

    /// Listen for global auth failures from any API call and auto-logout.
    public func observeAuthFailures() {
        NotificationCenter.default.addObserver(
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

    public func restoreSession() async {
        // 截图测试：要求 LoginView 时跳过恢复，否则 keychain 残留的 token
        // 会让 ContentView 直接展示 Dashboard。生产 build 永远不会进这个分支。
        if CommandLine.arguments.contains("UI_TEST_SHOW_LOGIN") {
            return
        }

        let savedToken = KeychainManager.load(server: server)
            ?? UserDefaults.standard.string(forKey: "auth_token")
        guard let token = savedToken else { return }

        client.setToken(token)

        // Verify token is still valid
        do {
            let me = try await client.getMe()
            applyMe(me)
        } catch {
            // Token expired or revoked — clear and stay on login screen
            KeychainManager.delete(server: server)
            UserDefaults.standard.removeObject(forKey: "auth_token")
            client.setToken(nil)
        }
    }

    // MARK: - Login

    public func loginAsAdmin(password: String, ttlDays: Int = 90) async {
        await login(username: "__admin__", password: password, ttlDays: ttlDays)
    }

    public func loginAsUser(name: String, password: String, ttlDays: Int = 90) async {
        await login(username: name, password: password, ttlDays: ttlDays)
    }

    private func login(username: String, password: String, ttlDays: Int) async {
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
