import XCTest
@testable import FlatRadarCore

/// 钥匙串在**签过名、开了 Sandbox、带描述文件**的 Mac 宿主里能不能用。
///
/// 这条测试的全部意义在于「跑在哪儿」
/// --------------------------------
/// macOS 的 data protection 钥匙串要求签名带 `application-identifier`，那个
/// entitlement 来自描述文件，而描述文件要求这台 Mac 在开发者账号里注册过。
/// 换句话说：**同一份代码，签名条件不同结果就不同**。
///
/// 2026-09-09 实测过三种条件（都是签名 + 沙盒的真二进制）：
///
///     data protection + 无描述文件   →  -34018 errSecMissingEntitlement
///     旧式文件式钥匙串 + 无描述文件   →  增 / 查 / 删 全过
///     data protection + 有描述文件   →  增 / 查 / 删 全过   ← 现在这条
///
/// 所以这条不能放包测试（`swift test` 的可执行文件没有这套 entitlements），
/// 也不能只靠 `--keychain-selftest` 手跑——那要人记得跑。
final class KeychainMacTests: XCTestCase {

    @MainActor
    func testKeychainReadWriteDeleteInSignedSandboxedHost() {
        let r = KeychainDiagnostics.run()
        XCTAssertTrue(r.allPassed, r.steps.joined(separator: " / "))
    }

    /// Mac 路径不继承 iOS 那条静默回退，所以这里永远不该有东西。
    @MainActor
    func testNoUserDefaultsFallbackTokenOnMac() {
        XCTAssertFalse(KeychainDiagnostics.hasUserDefaultsFallbackToken,
                       "Mac 上出现了 UserDefaults 回退 token —— 那条回退只在 iOS 编译")
    }
}
