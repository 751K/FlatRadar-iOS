import Foundation
import Security

/// 钥匙串操作失败。
///
/// 为什么单独立一个错误类型
/// ------------------------
/// 迁移前 ``KeychainManager`` 抛的是 `APIError.serverError("Keychain save failed
/// (OSStatus …)")`。两个问题：
///
/// 1. **类别错了。** 钥匙串写不进去跟服务器没有任何关系，混进 `APIError` 之后
///    调用方没法区分「后端 500」和「本机钥匙串没权限」。
/// 2. **诊断信息被吞了。** `APIError.serverError` 的 `errorDescription` 是通用的
///    "Server Error"，OSStatus 在 associated value 里但没人看得见。2026-09-09
///    第一次在 macOS 上跑自检，屏幕上就是「写入 失败 — Server Error」——
///    真正的原因（缺 entitlement）一个字都没露出来。
public struct KeychainError: LocalizedError, Equatable, Sendable {

    public let operation: String
    public let status: OSStatus

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    /// 系统给的解释，加上几个常撞的码的**具体**下一步。
    ///
    /// `SecCopyErrorMessageString` 对 -34018 只会说 "A required entitlement isn't
    /// present"，不会告诉你该去加哪个 entitlement。缺什么补什么写在这儿。
    public var errorDescription: String? {
        let sys = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain \(operation) failed: \(sys) (OSStatus \(status))\(hint)"
    }

    private var hint: String {
        switch status {
        case errSecMissingEntitlement:      // -34018
            return "\n— data protection 钥匙串要求签名带 application-identifier。"
                 + "macOS 上把 keychain-access-groups 加进 entitlements（Keychain "
                 + "Sharing 能力）才会签发带它的描述文件。见 docs/MACOS.md 风险 2。"
        case errSecDuplicateItem:           // -25299
            return "\n— 条目已存在；写入前应该先 delete。"
        case errSecItemNotFound:            // -25300
            return "\n— 条目不存在。查询和写入的钥匙串不是同一个时也会这样"
                 + "（kSecUseDataProtectionKeychain 三处必须一致）。"
        case errSecInteractionNotAllowed:   // -25308
            return "\n— 钥匙串被锁或不允许交互。"
        default:
            return ""
        }
    }
}
