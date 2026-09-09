import XCTest
import Security
@testable import FlatRadarCore

/// 钥匙串在**真机 + 真 entitlements** 下能不能用。
///
/// 为什么这条测试必须在 app 的测试目标里，不能放包测试
/// --------------------------------------------------
/// 钥匙串能不能写，取决于运行它的那个进程拿到了什么 entitlements。
/// `swift test` 出来的可执行文件既不是 `com.j.kong.FlatRadar`、也没有签名带
/// 的 application-identifier——在那里跑通了，证明不了 App 里也跑得通。
/// 这个 target 的宿主是真正的 `FlatRadar.app`，跑在真机上，条件才是对的。
///
/// 2026-09-09 加这条的直接原因
/// ---------------------------
/// 那天给 `KeychainManager` 的增 / 查 / 删都加了 `kSecUseDataProtectionKeychain`
/// （macOS 需要，见 `KeychainManager.dataProtection`）。iOS 上这个键被系统忽略，
/// 所以理论上行为不变——但「理论上不变」正是 2.1.0 那次线上无限崩溃的措辞。
/// 线上有真实用户，钥匙串一旦写不进去，所有人下次启动都要重新登录，而且
/// **不会有任何报错**：`AuthStore` 会静默回退到 `UserDefaults`。
///
/// 所以这里实跑一遍增 / 查 / 删。用的是 `.invalid` 保留域名下的独立条目，
/// 不碰真实会话。
final class KeychainTests: XCTestCase {

    /// 模拟器里的测试宿主**没有签名、没有描述文件**，也就没有
    /// `application-identifier`——而 data protection 钥匙串正是靠它授权的。
    /// 于是写入必然 -34018，这是环境的结构性限制，不是产品回归。
    ///
    /// 只在模拟器 **且** 恰好是 -34018 时跳过：
    ///
    /// - 真机上出现 -34018 说明 entitlement 真的丢了，那是**必须**红的回归；
    /// - 模拟器上出现别的错误码（比如 -25303 那个非法属性）照样红——
    ///   那正是这条测试当初逮到的东西，不能因为跑在模拟器上就放过。
    ///
    /// 2026-09-09 加这条测试时只在 iPad 上跑过，没看 GitHub Actions，
    /// 结果 CI 连红 5 次提交。教训写在这儿：本地真机绿 ≠ CI 绿。
    private func skipIfSimulatorLacksKeychainEntitlement(_ r: KeychainSelfTest) throws {
        #if targetEnvironment(simulator)
        if !r.saved, r.failureStatus == errSecMissingEntitlement {
            throw XCTSkip("模拟器宿主未签名，没有 application-identifier，"
                          + "data protection 钥匙串在这里结构性不可用。"
                          + "真机上这条会真跑——见 docs/MACOS.md 风险 2。")
        }
        #endif
    }

    // `KeychainDiagnostics.run()` 是 MainActor 隔离的（它转手调
    // `KeychainManager`，那是包里默认隔离下的类型）。测试跟着标。
    @MainActor
    func testKeychainReadWriteDeleteOnThisDevice() throws {
        let result = KeychainDiagnostics.run()
        try skipIfSimulatorLacksKeychainEntitlement(result)
        XCTAssertTrue(result.saved,
                      "钥匙串写入失败 —— \(result.steps.joined(separator: " / "))")
        XCTAssertTrue(result.loadedMatches,
                      "写进去了但读不回来 —— \(result.steps.joined(separator: " / "))")
        XCTAssertTrue(result.deleted,
                      "删除后仍能查到 —— \(result.steps.joined(separator: " / "))")
    }

    /// 自检必须用完就清干净，不给下一次留残留。
    @MainActor
    func testSelfTestLeavesNothingBehind() throws {
        let first = KeychainDiagnostics.run()
        try skipIfSimulatorLacksKeychainEntitlement(first)
        let second = KeychainDiagnostics.run()
        XCTAssertTrue(second.saved,
                      "第二次自检写入失败，说明上一次没删干净（errSecDuplicateItem）")
        XCTAssertTrue(second.allPassed)
    }
}
