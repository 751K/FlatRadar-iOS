import Foundation
import LocalAuthentication

/// 生物识别凭据那条钥匙串路径的自检。
///
/// 为什么需要它
/// ------------
/// ``BiometricAuthService`` 存的是一条带 `SecAccessControl`（`.biometryCurrentSet`）
/// 的条目，读它要过 Touch ID——**没法在无人值守的测试里读**。于是最容易出问题的
/// 那一半反而测不到：增和查落没落在同一个钥匙串上。
///
/// 原打算这样绕开认证：查的时候只要 `kSecReturnAttributes`，不要 `kSecReturnData`，
/// 赌"系统只在取数据时才要求认证"。**这个赌法是错的，2026-09-17 实测推翻了。**
///
/// macOS 上 ``BiometricAuthService/accessControlFlags`` 是 `.userPresence`，
/// 而它明确允许密码和 Apple Watch 兜底——于是 `SecItemCopyMatching` 命中一条这样
/// 的条目时，**只要属性也照样弹**「输入密码 / 用手表解锁」。证据有两条：
///
/// 1. 跑 Mac 测试套时那个框会弹出来，没人按就是两条失败（`saved` / `found` 全 false）。
/// 2. 把那个测试删掉之后，整套测试从 2.3–7.9 秒掉到 **0.097 秒**。原来的注释把那
///    几秒记成"查一条 `.userPresence` 条目实测要 3.5–5 秒"的钥匙串延迟，
///    实际上那是弹窗在等人。
///
/// 所以**它现在没有自动化调用方**：`BiometricMacTests` 已删（一个会弹框要人按的
/// 测试不能留在套件里，它把整套变成不能无人值守）。留着这个探针是因为那条路仍然
/// 值得在一台有 Touch ID 的机器上手验一次——照 `--keychain-selftest` 的样子接一个
/// 命令行入口就能跑，那个入口还没做。
///
/// 要验的是什么：增和查有没有落在同一个钥匙串上（漏
/// `kSecUseDataProtectionKeychain` 时会落在两个上，表现是"存了但读不到"）。
public enum BiometricDiagnostics {

    /// 探针用的账号，和真凭据分开，跑完就删。
    private static let probeAccount = "flatradar_biometric_selftest"
    private static let probeService = "com.flatradar.biometric.selftest"

    public nonisolated struct Report: Sendable {
        /// 这台机器上能不能用生物识别。false 不代表失败——Mac 可能根本没有
        /// Touch ID，或者没录指纹。
        public let biometryAvailable: Bool
        /// `LAContext.biometryType`：0 无 / 1 Touch ID / 2 Face ID。
        /// 注意它和 `biometryAvailable` 是两回事——有硬件但没录指纹时
        /// 类型是 1 而可用性是 false。
        public let biometryType: Int
        /// `canEvaluatePolicy` 给出的错误码，可用时为 nil。
        public let availabilityError: Int?
        /// 带访问控制的条目写进去了吗。
        public let saved: Bool
        /// **写完还能不能找到**——这条就是 data protection 钥匙串那个坑的判据。
        public let found: Bool
        public let deleted: Bool
        public let steps: [String]

        /// 钥匙串这一半是不是通的。生物识别可用性不算在内：那是机器的属性，
        /// 不是代码的。
        public var keychainPathWorks: Bool { saved && found && deleted }
    }

    public static func run() -> Report {
        var steps: [String] = []

        let ctx = LAContext()
        var laError: NSError?
        let available = ctx.canEvaluatePolicy(BiometricAuthService.policy, error: &laError)
        steps.append(available ? "解锁门 可用（\(BiometricAuthService.unlockMethodName)）"
                               : "解锁门 不可用（LAError \(laError?.code ?? 0)）")

        // 访问控制和策略都从 `BiometricAuthService` 取，**不在这里各写一份**：
        // 探针要是用了另一套 flag，它验的就不是真凭据那条路。
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            BiometricAuthService.accessControlFlags,
            nil) else {
            steps.append("访问控制 创建失败")
            return Report(biometryAvailable: available, biometryType: ctx.biometryType.rawValue,
                          availabilityError: laError?.code, saved: false, found: false,
                          deleted: false, steps: steps)
        }

        delete()   // 上一次跑崩了也不至于卡住这一次

        var add: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: probeAccount,
            kSecAttrService as String: probeService,
            kSecValueData as String:   Data(UUID().uuidString.utf8),
            kSecAttrAccessControl as String: access,
        ]
        add.merge(dataProtection) { a, _ in a }
        let addClock = Date()
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        let addSecs = Date().timeIntervalSince(addClock)
        let saved = addStatus == errSecSuccess
        steps.append(saved ? String(format: "写入 成功（%.2fs）", addSecs)
                           : "写入 失败 — OSStatus \(addStatus)")

        // **只要属性，不要数据**：要了数据就会弹 Touch ID。
        var find: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: probeAccount,
            kSecAttrService as String: probeService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        find.merge(dataProtection) { a, _ in a }
        var out: AnyObject?
        let findClock = Date()
        let findStatus = SecItemCopyMatching(find as CFDictionary, &out)
        let findSecs = Date().timeIntervalSince(findClock)
        let found = findStatus == errSecSuccess
        steps.append(found ? String(format: "查找 成功（%.2fs）", findSecs)
                           : "查找 失败 — OSStatus \(findStatus)"
                             + (findStatus == errSecItemNotFound
                                ? "（写进去了却找不到 = 增和查落在两个钥匙串上）" : ""))

        delete()
        var gone: [String: Any] = find
        gone[kSecReturnAttributes as String] = nil
        var after: AnyObject?
        let deleted = SecItemCopyMatching(gone as CFDictionary, &after) == errSecItemNotFound
        steps.append(deleted ? "删除 成功" : "删除 失败 — 删完还能查到")

        return Report(biometryAvailable: available, biometryType: ctx.biometryType.rawValue,
                      availabilityError: laError?.code, saved: saved, found: found,
                      deleted: deleted, steps: steps)
    }

    private static func delete() {
        var q: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: probeAccount,
            kSecAttrService as String: probeService,
        ]
        q.merge(dataProtection) { a, _ in a }
        SecItemDelete(q as CFDictionary)
    }

    /// 和 ``BiometricAuthService`` 用同一条规则——探针要是走了另一个钥匙串，
    /// 它验的就不是真凭据那条路。
    private static var dataProtection: [String: Any] {
        #if os(macOS)
        [kSecUseDataProtectionKeychain as String: true]
        #else
        [:]
        #endif
    }
}
