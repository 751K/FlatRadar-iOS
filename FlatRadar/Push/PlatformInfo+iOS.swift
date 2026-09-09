import UIKit
import FlatRadarCore

extension PlatformInfo {

    /// iOS 宿主注入给 Core 的平台信息。
    ///
    /// 迁移前这些值散在 Core 里直接读 `UIDevice`，Mac 上编不过。现在由宿主提供，
    /// 每个字段都对应迁移前的同一个读法，行为不变：
    ///
    /// | 字段 | 迁移前 |
    /// |---|---|
    /// | `deviceName` | `UIDevice.current.name` |
    /// | `systemVersion` | `UIDevice.current.systemVersion` |
    /// | `hardwareModel` | `PushStore.currentModel`（`utsname.machine`） |
    /// | `platformId` | `APIClient.registerDevice` 里硬编码的 `"ios"` |
    ///
    /// `cpuArchitecture` 是新增的：iOS 上 `utsname.machine` 就是机型，架构另外给，
    /// 免得 Mac 那边照抄这份实现时把两者混成一个字段。
    @MainActor
    static var iOS: PlatformInfo {
        PlatformInfo(
            platformId: "ios",
            deviceName: UIDevice.current.name,
            systemVersion: UIDevice.current.systemVersion,
            hardwareModel: PlatformInfo.unameMachine,
            cpuArchitecture: {
                #if arch(arm64)
                return "arm64"
                #else
                return "x86_64"
                #endif
            }())
    }
}
