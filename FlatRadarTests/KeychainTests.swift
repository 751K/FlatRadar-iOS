import XCTest
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

    // `KeychainDiagnostics.run()` 是 MainActor 隔离的（它转手调
    // `KeychainManager`，那是包里默认隔离下的类型）。测试跟着标。
    @MainActor
    func testKeychainReadWriteDeleteOnThisDevice() {
        let result = KeychainDiagnostics.run()
        XCTAssertTrue(result.saved,
                      "钥匙串写入失败 —— \(result.steps.joined(separator: " / "))")
        XCTAssertTrue(result.loadedMatches,
                      "写进去了但读不回来 —— \(result.steps.joined(separator: " / "))")
        XCTAssertTrue(result.deleted,
                      "删除后仍能查到 —— \(result.steps.joined(separator: " / "))")
    }

    /// 自检必须用完就清干净，不给下一次留残留。
    @MainActor
    func testSelfTestLeavesNothingBehind() {
        _ = KeychainDiagnostics.run()
        let second = KeychainDiagnostics.run()
        XCTAssertTrue(second.saved,
                      "第二次自检写入失败，说明上一次没删干净（errSecDuplicateItem）")
        XCTAssertTrue(second.allPassed)
    }
}
