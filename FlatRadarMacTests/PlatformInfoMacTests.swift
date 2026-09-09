import XCTest
import FlatRadarCore
@testable import FlatRadarMac

/// macOS 平台适配层的守卫。
///
/// 为什么要有独立的 Mac 测试目标
/// ----------------------------
/// `PlatformInfo.macOS` 定义在 Mac app 里，包测试和 iOS 测试都看不见它。
/// 而它承载的是 docs/MACOS.md 风险 4 那条**隐私**约束——那条约束一旦被"顺手改
/// 回去"，没有任何别的检查会发现。
final class PlatformInfoMacTests: XCTestCase {

    /// 风险 4：登录 / 注册请求体里的设备名**不能是系统主机名**。
    ///
    /// 迁移前 Core 里写的是 `Host.current().name ?? "Mac"`。macOS 的主机名
    /// 常包含用户姓名（"张三的 MacBook Pro"），把它发给后端等于凭空多采一项
    /// 个人信息，而 `PrivacyInfo.xcprivacy` 并没有声明这一项。换
    /// `localizedName` 也不解决——它同样来自用户起的名字。
    ///
    /// 这条测试钉的是结果不是实现：只要注入的值不再是常量，就红。
    @MainActor
    func testDeviceNameIsANeutralConstant() {
        XCTAssertEqual(PlatformInfo.macOS.deviceName, "Mac",
                       "Mac 的设备名必须是中性常量，见 docs/MACOS.md 风险 4")
    }

    /// 万一哪天有人把 `Host.current()` 加回来，这条会在**这台机器**上红。
    ///
    /// 分开写是因为上面那条在主机名恰好等于 "Mac" 时抓不到回归。
    @MainActor
    func testDeviceNameIsNotDerivedFromTheHostname() throws {
        let host = Host.current()
        let candidates = [host.name, host.localizedName].compactMap(\.self)
        try XCTSkipIf(candidates.contains("Mac"),
                      "这台机器的主机名恰好是 Mac，这条测试在这里没有分辨力")
        XCTAssertFalse(candidates.contains(PlatformInfo.macOS.deviceName),
                       "设备名等于系统主机名 \(candidates)——主机名常含用户姓名")
    }

    @MainActor
    func testHardwareModelIsNotTheCPUArchitecture() {
        let info = PlatformInfo.macOS
        // `utsname.machine` 在 iOS 上是机型（iPhone16,2），在 Mac 上是架构
        // （arm64）。两者语义不同，不能拿架构冒充机型。
        XCTAssertNotEqual(info.hardwareModel, info.cpuArchitecture,
                          "hardwareModel 不能直接用 utsname.machine 的结果")
        XCTAssertFalse(info.systemVersion.isEmpty)
        XCTAssertEqual(info.platformId, "macos")
    }
}
