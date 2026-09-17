import Foundation
import LocalAuthentication

// MARK: - Biometric authentication service

/// Face ID / Touch ID 封装：检测可用性 + 触发认证 + 读取 Keychain 中受生物特征保护的凭据。
public enum BiometricAuthService {
    /// 本地存储的生物凭据：登录凭据（不含其他加密数据）。
    public nonisolated struct StoredCredential: Codable {
        public let username: String
        public let password: String
        public let role: String       // "user" | "admin"

        /// 逐成员构造器随 `public` 变 internal，设置页的"开启生物识别"用不了。
        public init(username: String, password: String, role: String) {
            self.username = username
            self.password = password
            self.role = role
        }
    }

    private static let credAccount = "flatradar_biometric"
    private static let credService = "com.flatradar.biometric"

    /// macOS 上必须显式要 **data protection 钥匙串**，iOS 上这个键被忽略。
    ///
    /// 不设它的话 macOS 走旧的文件式钥匙串（login.keychain），而这里存的是一条
    /// 带 `SecAccessControl`（`.biometryCurrentSet`）的条目——旧钥匙串对
    /// `kSecAttrAccessible` 和访问控制的解释都和 iOS 那套不一样，签名没有
    /// `application-identifier` 时写入直接 **-34018 errSecMissingEntitlement**。
    ///
    /// **三处必须一致**（增 / 删 / 查）：只要有一处漏了，增和查就落在**两个不同的
    /// 钥匙串**上，表现是"存进去了但读不到"——Touch ID 弹了、用户按了、然后
    /// 什么也没发生。和 ``KeychainManager/dataProtection`` 是同一条坑，
    /// 那边的注释里有 Apple TN3137 的出处。
    ///
    /// Mac 端的 entitlements 里那条 Keychain Sharing 就是为这个签出
    /// `application-identifier` 的，不是为了真的和谁共享。
    private static var dataProtection: [String: Any] {
        #if os(macOS)
        [kSecUseDataProtectionKeychain as String: true]
        #else
        [:]
        #endif
    }

    // MARK: - 两端的门不一样

    /// 解锁这条凭据要过哪一道门。
    ///
    /// | | 策略 | 访问控制 | 谁能开 |
    /// |---|---|---|---|
    /// | iOS | `.deviceOwnerAuthenticationWithBiometrics` | `.biometryCurrentSet` | 只有 Face ID / Touch ID |
    /// | macOS | `.deviceOwnerAuthentication` | `.userPresence` | Touch ID / Apple Watch / 开机密码 |
    ///
    /// **为什么 Mac 要松一档**：`.biometryCurrentSet` 在没有生物识别的机器上
    /// 连写都写不进去——实测这台 Mac mini（M4，无 Touch ID）
    /// `SecItemAdd` 直接 -25293 errSecAuthFailed，`canEvaluatePolicy` 报
    /// LAError -12 `biometryNotPaired`。台式 Mac 大多如此，照搬 iOS 等于这个功能
    /// 在半数 Mac 上永远不出现，而且**静默不出现**。
    ///
    /// 松的这一档换来什么、丢掉什么要说清楚：丢的是"只有你的指纹能开"，
    /// 换成"能解锁这台 Mac 的人能开"。而能解锁这台 Mac 的人本来就能直接用
    /// 你已经登录的 FlatRadar——这条凭据挡不住的，他绕开它也拿得到。
    /// Safari 的自动填充、1Password 的解锁走的都是这一条。
    ///
    /// iOS 那边**不动**：线上有真实用户，而且 iPhone 一定有生物识别，
    /// 没有任何理由降级。
    static var policy: LAPolicy {
        #if os(macOS)
        .deviceOwnerAuthentication
        #else
        .deviceOwnerAuthenticationWithBiometrics
        #endif
    }

    static var accessControlFlags: SecAccessControlCreateFlags {
        #if os(macOS)
        .userPresence
        #else
        .biometryCurrentSet
        #endif
    }

    /// 界面上怎么称呼这道门。**不能一律写 Touch ID**：这台 Mac 上按下去弹的是
    /// 开机密码框，标签却写着 Touch ID，那是在骗人。
    public static var unlockMethodName: String {
        let ctx = LAContext()
        // ⚠️ 必须问**严格的那一档**，不能问 `policy`。
        //
        // `biometryType` 报的是"这台机器属于哪一类"，不是"现在能不能用"：
        // 这台 Mac mini 没有 Touch ID，`biometryType` 照样是 `.touchID`。
        // 第一版就是先 `canEvaluatePolicy(policy)`（macOS 上是宽的那档，
        // 返回 true）再读 `biometryType`，于是标签写着 Touch ID，按下去
        // 弹的却是开机密码框——正是这个方法本来要防的那件事。
        let biometryUsable = ctx.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics, error: nil)
        if biometryUsable {
            switch ctx.biometryType {
            case .faceID:  return "Face ID"
            case .touchID: return "Touch ID"
            default:       break
            }
        }
        #if os(macOS)
        // 生物识别用不了时，这道门实际就是开机密码（或 Apple Watch）。
        return "your password"
        #else
        return "Biometrics"
        #endif
    }

    // MARK: - Availability

    public static var isAvailable: Bool {
        var error: NSError?
        let available = LAContext().canEvaluatePolicy(policy, error: &error)
        return available
    }

    public static var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(policy, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Biometrics"
        }
    }

    /// 仅 user 凭据才显示 Face ID 按钮。
    /// 直接读 UserDefaults role 标记——不碰 Keychain（生物保护条目查询可能意外触发面容提示）。
    public static var hasStoredCredentials: Bool {
        UserDefaults.standard.string(forKey: "biometric_role") == "user"
    }

    // MARK: - Save / Delete

    public static func saveCredentials(_ cred: StoredCredential) throws {
        deleteCredentials()

        let data = try JSONEncoder().encode(cred)
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            accessControlFlags,
            nil
        ) else {
            throw NSError(domain: "BiometricAuth", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create access control"])
        }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: credAccount,
            kSecAttrService as String: credService,
            kSecValueData as String:   data,
            kSecAttrAccessControl as String: access,
        ].merging(dataProtection) { a, _ in a }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "BiometricAuth", code: Int(status),
                         userInfo: [NSLocalizedDescriptionKey: "Keychain save failed (OSStatus \(status))"])
        }
        // 角色标记存 UserDefaults（无生物保护），供 hasStoredCredentials 过滤
        UserDefaults.standard.set(cred.role, forKey: "biometric_role")
    }

    public static func deleteCredentials() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: credAccount,
            kSecAttrService as String: credService,
        ].merging(dataProtection) { a, _ in a }
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "biometric_role")
    }

    // MARK: - Authenticate + load

    /// 触发生物认证，成功后从 Keychain 读取凭据。
    /// - Parameter reason: Face ID 提示文字
    /// - Returns: 解密后的凭据；认证失败 / 凭据不存在时返回 nil
    public static func authenticateAndLoad(reason: String) async -> StoredCredential? {
        guard isAvailable else { return nil }

        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Enter Password"
        ctx.localizedReason = reason

        do {
            let success = try await ctx.evaluatePolicy(
                Self.policy,
                localizedReason: reason
            )
            guard success else { return nil }
        } catch {
            return nil
        }

        // 复用已认证的 LAContext 读取 Keychain —— 避免二次弹出系统面容提示，
        // 同时解决 kSecUseOperationPrompt 在 iOS 14 已废弃的问题。
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrAccount as String:        credAccount,
            kSecAttrService as String:        credService,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: ctx,
        ].merging(dataProtection) { a, _ in a }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let cred = try? JSONDecoder().decode(StoredCredential.self, from: data) else {
            return nil
        }
        return cred
    }
}
