import XCTest
import Security
@testable import FlatRadarMac
@testable import FlatRadarCore

/// Mac 注册推送时发给后端的两个字段。
///
/// 后端 v1.41.0（`290a61e`）起接受 Mac 设备，约定是：
///
/// - `platform` 必须是 `"macos"`——后端现在对未知平台直接 400，而且按
///   `APNS_PLATFORMS = {"ios", "macos"}` 白名单分流；
/// - debug 包 `env` 必须是 `"sandbox"`——Xcode 直接 Run 拿到的是 sandbox token，
///   报成 production 的话 APNs 回 `BadDeviceToken`，后端会把这台设备标成失效。
///
/// 为什么不能只看 `#if DEBUG`
/// ------------------------
/// `docs/MACOS.md` 风险 3 的验收要求原话是「APNs 环境依据最终签名配置验证，
/// 不只凭 `DEBUG` 推断」。token 属于哪个环境，是**签进二进制的
/// `com.apple.developer.aps-environment`** 决定的，不是编译条件。两者碰巧
/// 一致只是 Xcode 的默认流程（Debug 用开发描述文件签）——所以第三条用例直接从
/// 这个进程读签名里的 entitlement，和 `PushStore.currentEnv` 对账。
///
/// 这些用例跑在 `FlatRadarMac.app` 宿主进程里（`TEST_HOST`），读到的就是真正签过名
/// 的那个 app 的 entitlements，不是测试 bundle 自己的。
final class PushRegistrationTests: XCTestCase {

    @MainActor
    func test_上报的平台是macos() {
        XCTAssertEqual(PlatformEnvironment.info.platformId, "macos",
                       "后端对未知 platform 返回 400；报成 ios 则面板和统计里会把这台 Mac 记成 iPhone")
    }

    /// `#if DEBUG` 写在**包**里（`PushStore`），而这里跑的是 Xcode 用 Mac target 的
    /// Debug 配置编出来的包——包能不能看到 `DEBUG` 取决于构建方式，不是理所当然。
    @MainActor
    func test_debug包报sandbox() {
        #if DEBUG
        XCTAssertEqual(PushStore.currentEnv, "sandbox")
        #else
        XCTAssertEqual(PushStore.currentEnv, "production")
        #endif
    }

    /// 回归用例本体：代码报的环境 = 签名里的环境。
    @MainActor
    func test_env和签名里的aps环境一致() throws {
        let signed = try XCTUnwrap(
            Self.entitlement("com.apple.developer.aps-environment") as? String,
            "签名里没有 com.apple.developer.aps-environment——注册会在 didFailToRegister 里失败。"
            + "注意 macOS 的键名带 com.apple.developer. 前缀，iOS 那个裸的 aps-environment 在这里不认。")

        // entitlement 用 development / production，后端的 env 用 sandbox / production。
        let expected: String
        switch signed {
        case "development": expected = "sandbox"
        case "production":  expected = "production"
        default: return XCTFail("没见过的 aps-environment 值：\(signed)")
        }
        XCTAssertEqual(PushStore.currentEnv, expected,
                       "签名是 \(signed)，代码却报 \(PushStore.currentEnv)——APNs 会拒这个 token")
    }

    /// 发出去的请求体长什么样。字段名是后端契约（`DeviceRegisterRequest`），
    /// 这条防的是有人给 `platform` 换了 CodingKey 或者写死了值。
    @MainActor
    func test_注册请求体带上这两个字段() throws {
        let body = DeviceRegisterRequest(
            deviceToken: String(repeating: "a", count: 64),
            env: PushStore.currentEnv,
            platform: PlatformEnvironment.info.platformId,
            model: "Mac", bundleId: "com.j.kong.FlatRadar",
            language: "en", osVersion: "26.0")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(json["platform"] as? String, "macos")
        #if DEBUG
        XCTAssertEqual(json["env"] as? String, "sandbox")
        #endif
    }

    // MARK: - 工具

    /// 从**当前进程**的代码签名里读一个 entitlement。
    private static func entitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }
}
