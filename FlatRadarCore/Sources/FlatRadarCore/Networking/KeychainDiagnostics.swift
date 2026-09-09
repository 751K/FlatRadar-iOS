import Foundation

/// 钥匙串自检的结果。
///
/// `nonisolated`：纯值类型，全是 `let`，没有任何可变状态。工程开着
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（包里是
/// `.defaultIsolation(MainActor.self)`），不标注就会被隐式钉在主 actor 上，
/// 于是 nonisolated 的测试方法连读一个字段都报错。
public nonisolated struct KeychainSelfTest: Sendable, Equatable {
    public let saved: Bool
    public let loadedMatches: Bool
    public let deleted: Bool
    /// 逐步说明，直接显示给人看。**不含任何凭据**。
    public let steps: [String]

    public var allPassed: Bool { saved && loadedMatches && deleted }
}

/// 钥匙串的运行时自检。
///
/// 为什么需要它
/// ------------
/// docs/MACOS.md Phase 1 的完成判据里有一条「Keychain 写入、读取、删除均返回
/// 成功」。**「登录成功」证明不了这一条**：写失败时 iOS 会静默回退到
/// `UserDefaults`、Mac 会把 ``AuthStore/sessionSavedToKeychain`` 置 false，
/// 两种情况下登录本身都照样成功、界面上也看不出区别。
///
/// 而 macOS 的钥匙串有一整排能让写入失败的前提：签名、entitlements、data
/// protection 钥匙串（见 ``KeychainManager``）、App Sandbox。文档明确写着
/// 「不以『勾了能力』代替运行验证」——这就是那个运行验证。
///
/// 用一个**独立的测试条目**（`server` 是保留的 .invalid 域名），不碰真实会话。
public enum KeychainDiagnostics {

    /// RFC 2606 保留的 .invalid 顶级域，保证不会和任何真实服务器撞上。
    private static let probeServer = "keychain-selftest.flatradar.invalid"

    /// 走一遍增 → 查 → 删，报告每一步。
    public static func run() -> KeychainSelfTest {
        // 随机值，不是凭据；即便如此也不写进日志或返回值。
        let secret = UUID().uuidString
        var steps: [String] = []

        do {
            try KeychainManager.save(token: secret, server: probeServer)
            steps.append("写入 成功")
        } catch {
            steps.append("写入 失败 — \(error.localizedDescription)")
            return KeychainSelfTest(saved: false, loadedMatches: false,
                                    deleted: false, steps: steps)
        }

        let back = KeychainManager.load(server: probeServer)
        let matches = back == secret
        steps.append(matches ? "读取 成功（值一致）"
                             : back == nil ? "读取 失败 — 查不到刚写进去的条目"
                                           : "读取 失败 — 取回的值与写入的不一致")

        KeychainManager.delete(server: probeServer)
        let gone = KeychainManager.load(server: probeServer) == nil
        steps.append(gone ? "删除 成功" : "删除 失败 — 删完还能查到")

        return KeychainSelfTest(saved: true, loadedMatches: matches,
                                deleted: gone, steps: steps)
    }

    /// `UserDefaults` 里有没有回退存下的 bearer token。
    ///
    /// 完成判据里的「确认没有触发 UserDefaults token 回退」查的就是它。
    /// Mac 上永远应该是 `false`——那条回退只在 iOS 编译（见
    /// ``AuthStore/sessionSavedToKeychain``）。为 true 说明要么在 iOS 上跑，
    /// 要么是历史残留，两种都得说清楚而不是当没看见。
    public static var hasUserDefaultsFallbackToken: Bool {
        UserDefaults.standard.string(forKey: "auth_token") != nil
    }
}
