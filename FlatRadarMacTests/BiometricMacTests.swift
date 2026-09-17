import XCTest
@testable import FlatRadarCore

/// Touch ID 那条钥匙串路径，在**签过名、开了沙盒、带描述文件**的 Mac 宿主里。
///
/// 和 ``KeychainMacTests`` 是同一个道理：同一份代码，签名条件不同结果就不同，
/// 所以只能在这个 target 里跑，不能放包测试（`swift test` 的可执行文件没有这套
/// entitlements）。
///
/// 它守的具体是什么
/// ----------------
/// `BiometricAuthService` 原先三条 SecItem 查询都**没有**
/// `kSecUseDataProtectionKeychain`。macOS 上那意味着走旧的文件式钥匙串，而存的
/// 又是一条带 `.biometryCurrentSet` 访问控制的条目——签名没有
/// `application-identifier` 时写入直接 -34018；就算写进去了，只要增和查有一处
/// 不一致，就落在两个不同的钥匙串上，表现是"Touch ID 弹了、按了、什么也没发生"。
///
/// 这条测试**不碰认证**：查的时候只要属性不要数据，所以不会弹 Touch ID，
/// 能在无人值守下跑。剩下那一半只能手动验。
final class BiometricMacTests: XCTestCase {

    /// 三条测试共用**一次**探针。
    ///
    /// 不共用的话整个 Mac 测试套从 0.1 秒涨到 34 秒：查一条 `.userPresence`
    /// 保护的条目实测要 3.5–5 秒（`SecItemCopyMatching` 那一步，写入本身是
    /// 0.00 秒），跑三遍就是三倍。
    ///
    /// 顺带说明一件事：这个慢只在**读**那条路上，而读只发生在用户点了
    /// 「用 Touch ID 登录」之后——那时本来就有一个系统认证框在等他。
    /// 界面上会调的是 `isAvailable`（`canEvaluatePolicy`），实测 6 毫秒，
    /// 放在 `body` 里安全。
    @MainActor
    private static let report: BiometricDiagnostics.Report = BiometricDiagnostics.run()

    /// ⚠️ 这台开发机（Mac mini M4）**没有 Touch ID**，所以这条会 skip 而不是过。
    ///
    /// 不是"顺手跳过"：带 `.biometryCurrentSet` 的条目在没有可用生物识别时
    /// **写都写不进去**（实测 `SecItemAdd` → -25293 errSecAuthFailed），
    /// 这是系统的正确行为，不是我们的 bug。硬断言下去只会得到一条永远红的测试，
    /// 而永远红的测试等于没有测试。
    ///
    /// 有 Touch ID 的机器上（带 Touch ID 的 MacBook，或配了 Touch ID 妙控键盘的
    /// Mac mini）它会真的跑起来。**换句话说 `kSecUseDataProtectionKeychain`
    /// 那个修复在这台机器上验不了**，这一点必须说出来，不能当成验过。
    @MainActor
    func testBiometricKeychainRoundTripInSignedSandboxedHost() throws {
        let r = Self.report
        try XCTSkipUnless(r.biometryAvailable,
                          "这台机器没有可用的生物识别（LAError "
                        + "\(r.availabilityError.map(String.init) ?? "-")），"
                        + "带 .biometryCurrentSet 的条目写不进去——跳过而不是判失败")
        XCTAssertTrue(r.keychainPathWorks, r.steps.joined(separator: " / "))
    }

    /// 写进去之后必须找得到。单独拎出来是因为它是那个坑**唯一**的直接判据：
    /// `saved == true && found == false` 就是"两个钥匙串"那个现场。
    @MainActor
    func testSavedItemIsFoundInTheSameKeychain() throws {
        let r = Self.report
        try XCTSkipUnless(r.biometryAvailable, "没有生物识别，写不进去，无从比对")
        XCTAssertTrue(r.saved, "写入就失败了：\(r.steps.joined(separator: " / "))")
        XCTAssertTrue(r.found,
                      "写进去了却查不到——增和查落在两个不同的钥匙串上。"
                    + "\(r.steps.joined(separator: " / "))")
    }

    /// 这台机器上生物识别可不可用是**机器的属性**，不是代码的，所以不断言它。
    /// 只把实测值打出来：界面要不要显示 Touch ID 入口取决于它。
    @MainActor
    func testReportsBiometryAvailability() {
        let r = Self.report
        print("[Biometric] available=\(r.biometryAvailable) "
            + "type=\(r.biometryType) err=\(r.availabilityError.map(String.init) ?? "-")")
        print("[Biometric] steps: \(r.steps.joined(separator: " | "))")
        XCTAssertTrue((0...2).contains(r.biometryType), "biometryType 超出已知取值")
    }
}
