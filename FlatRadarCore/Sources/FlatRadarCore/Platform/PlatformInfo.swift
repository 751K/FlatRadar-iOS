import Foundation

/// 宿主 app 注入的设备与平台**数据**。
///
/// 为什么是注入而不是在 Core 里写 `#if os(iOS)`
/// ------------------------------------------
/// Core 是两端共用的模块。平台判断一旦散进业务逻辑，测试里就没法替换，Mac 端也只能
/// 靠 `#else` 分支猜——`DeviceName.current` 的 `Host.current().name` 就是这么来的
/// （见 ``deviceName`` 的警告）。这里只放数据；系统**能力**（推送注册、权限查询）
/// 走 ``PushPlatformBridge``。两者不合并：合并会让这个类型变成什么都往里塞的口袋。
public struct PlatformInfo: Sendable, Equatable {

    /// 上报后端 `device_tokens.platform` 的标识。
    ///
    /// 后端当前的取值约束尚未核实（docs/MACOS.md 风险 3）。Mac 端真正注册设备前
    /// 必须先跟后端对齐，不能想当然填 "macos"。
    public var platformId: String

    /// 登录 / 注册请求里的设备名。
    ///
    /// ⚠️ **不能是系统主机名。** macOS 的 `Host.current().name` 常包含用户姓名
    /// （"张三的 MacBook Pro"），把它塞进登录请求体等于凭空多采一项个人信息，
    /// 而 `PrivacyInfo.xcprivacy` 并没有声明它。Mac 端注入中性常量。
    public var deviceName: String

    /// 系统版本，如 "18.5" / "26.0"。
    public var systemVersion: String

    /// 硬件标识符，如 "iPhone16,2"。
    ///
    /// ⚠️ 和 ``cpuArchitecture`` 分开是因为**两者在 Mac 上不是一回事**：
    /// `utsname.machine` 在 iOS 上给机型（"iPhone16,2"），在 Mac 上给的是
    /// CPU 架构（"arm64"）。想要 Mac 机型要读 IOKit 的 `model` 属性。
    /// Core 不做这个推断，各平台自己填。
    public var hardwareModel: String

    /// CPU 架构，如 "arm64" / "x86_64"。
    public var cpuArchitecture: String

    public init(
        platformId: String,
        deviceName: String,
        systemVersion: String,
        hardwareModel: String,
        cpuArchitecture: String
    ) {
        self.platformId = platformId
        self.deviceName = deviceName
        self.systemVersion = systemVersion
        self.hardwareModel = hardwareModel
        self.cpuArchitecture = cpuArchitecture
    }

    /// `uname()` 读出的 `machine` 字段。iOS 上是机型，Mac 上是 CPU 架构。
    public static var unameMachine: String {
        var s = utsname()
        uname(&s)
        let mirror = Mirror(reflecting: s.machine)
        return mirror.children
            .compactMap { ($0.value as? Int8).flatMap { $0 == 0 ? nil : UInt8(bitPattern: $0) } }
            .reduce(into: "") { $0.append(Character(UnicodeScalar($1))) }
    }
}

/// Core 读平台数据的唯一入口。宿主 app 在启动最早期 ``configure(_:)`` 一次。
public enum PlatformEnvironment {

    private static var stored: PlatformInfo?

    /// app 启动时调一次。重复调用以最后一次为准（切换测试替身用）。
    public static func configure(_ info: PlatformInfo) {
        stored = info
    }

    /// 没配置就用中性占位值，并在 DEBUG 下直接断言。
    ///
    /// 不 `fatalError`：漏配的后果是上报字段变成占位串，不该让线上 app 起不来。
    /// 但也不能静默——占位值会一路发到后端，DEBUG 断言保证开发期一定撞上。
    public static var info: PlatformInfo {
        if let stored { return stored }
        assertionFailure("PlatformEnvironment.configure(_:) 没在启动时调用")
        return PlatformInfo(
            platformId: "unknown", deviceName: "unknown",
            systemVersion: "0.0", hardwareModel: "unknown",
            cpuArchitecture: unameMachineFallback)
    }

    private static var unameMachineFallback: String { PlatformInfo.unameMachine }
}
