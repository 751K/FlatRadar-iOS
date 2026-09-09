import Foundation
import FlatRadarCore

extension PlatformInfo {

    /// macOS 宿主注入给 Core 的平台信息。
    ///
    /// ⚠️ **`deviceName` 是常量 `"Mac"`，不是主机名。**
    /// 迁移前 Core 里写的是 `Host.current().name ?? "Mac"`，而 macOS 主机名
    /// 常包含用户姓名（"张三的 MacBook Pro"）——登录 / 注册请求体会原样带上它。
    /// `PrivacyInfo.xcprivacy` 没有声明这一项采集，所以首次 Mac 登录之前必须堵掉。
    /// 换 `localizedName` 也不行，它同样来自用户起的名字。见 docs/MACOS.md 风险 4。
    ///
    /// `hardwareModel` 暂时也是常量：`utsname.machine` 在 Mac 上返回的是 CPU 架构
    /// （"arm64"），不是机型；真机型要读 IOKit 的 `model` 属性。在核实之前不拿架构
    /// 冒充机型，宁可上报一个明确的占位值。
    ///
    /// `platformId` 同理待定：后端 `device_tokens.platform` 的取值约束本次没核实
    /// （docs/MACOS.md 风险 3）。Phase 0 / 1 的 Mac 端不注册设备，这个值不会发出去。
    @MainActor
    static var macOS: PlatformInfo {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return PlatformInfo(
            platformId: "macos",
            deviceName: "Mac",
            systemVersion: "\(v.majorVersion).\(v.minorVersion)",
            hardwareModel: "Mac",
            cpuArchitecture: PlatformInfo.unameMachine)
    }
}
