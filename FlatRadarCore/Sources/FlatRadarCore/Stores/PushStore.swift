import Foundation
import SwiftUI
import UserNotifications

/// APNs 设备注册状态机。
///
/// 生命周期
/// --------
/// 1. App 启动：``FlatRadarApp.task`` 调 ``setup()``——挂 PushDelegate 钩子，
///    等待登录完成
/// 2. 登录成功：``AuthStore.login`` 触发 ``requestPermissionAndRegister()``
///    → 系统弹通知权限框 → 同意后向 APNs 注册 → 拿到 token
/// 3. PushDelegate 把 token 回传 ``handleDeviceToken(_:)``
/// 4. token 通过 ``APIClient.registerDevice`` 上报后端
/// 5. 登出：``logout()`` 删除后端绑定 + 解除 APNs 注册
///
/// 环境切换
/// --------
/// Xcode 直接 Run（DEBUG）拿到的 token 只对 sandbox 端点有效；
/// TestFlight / App Store（RELEASE）拿到的 token 对 production 有效。
/// ``Self.currentEnv`` 通过 ``#if DEBUG`` 自动切换。
@MainActor
@Observable
public final class PushStore {

    /// `defaults` 的默认值让宿主照旧 `PushStore()`，包测试又能注入替身
    /// （同 ``ReviewPromptStore``）。公开的是这一个 init，不另留空 init——
    /// 那会让 `defaults` 和 ``deliveryDisabledByUser`` 没机会赋值。
    public init(defaults: UserDefaults = .standard,
                notifications: any NotificationAuthorizing = SystemNotificationCenter()) {
        self.defaults = defaults
        self.notifications = notifications
        self.deliveryDisabledByUser = defaults.bool(forKey: Self.deliveryDisabledKey)
    }

    public enum PermissionStatus: Sendable {
        case notDetermined, denied, authorized, provisional, ephemeral
    }

    public var permissionStatus: PermissionStatus = .notDetermined
    var lastToken: String?
    public var lastError: String?
    public var registeredDeviceId: Int?

    /// 用户在设置里主动把推送关掉了。**按设备存，不按账号。**
    ///
    /// 为什么不能只看 ``registeredDeviceId``
    /// ------------------------------------
    /// ``setEnabled(false)`` 只删后端绑定，之后 `registeredDeviceId` 是 nil——
    /// 而这和「这台设备从没注册过」长得一模一样。冷启动时宿主对任何已登录的
    /// 非访客用户都会调 ``requestPermissionAndRegister()``，于是又注册回去，
    /// 开关读回来是开的：用户关掉的通知被 app 自己悄悄打开了。少的就是
    /// 「用户**选择**关掉」这条信息，只能单独存。
    ///
    /// 为什么存 UserDefaults 不存后端：通知权限本来就是**这台设备**的，不是
    /// 账号的。在 iPhone 上关掉不该顺手把 iPad 的也关掉；同理换个账号登进来，
    /// 这台设备的选择依然算数，所以 ``logout()`` 不清它。
    ///
    /// iOS 和 Mac 走同一份 Core，键名自然是同一个，不用各自抄一遍字符串。
    public private(set) var deliveryDisabledByUser: Bool

    /// ``deliveryDisabledByUser`` 的 UserDefaults 键名。
    ///
    /// `nonisolated`：类是 `@MainActor`，静态常量默认跟着隔离，于是读一个
    /// 字符串常量都得跳到主线程。它是不可变的 `String`，本来就是 Sendable，
    /// 没有需要保护的状态——宿主在别的 actor 上（或测试里）直接读键名才不会
    /// 被隔离挡住。
    public nonisolated static let deliveryDisabledKey = "pushDeliveryDisabledByUser"

    private let defaults: UserDefaults

    /// 通知权限那道系统门。默认是真的 `UNUserNotificationCenter`，
    /// 测试注入替身——理由写在 ``NotificationAuthorizing`` 上（一句话版：
    /// 干净环境下那个系统框没人点，`await` 永不返回）。
    private let notifications: any NotificationAuthorizing
    private let client = APIClient.shared
    private var hasInstalledDelegate = false

    /// 平台推送桥接。``setup(bridge:)`` 注入，之后 ``requestPermissionAndRegister``
    /// 用它触发注册。Core 不认识具体的 app delegate。
    private weak var bridge: (any PushPlatformBridge)?

    /// DEBUG / RELEASE → "sandbox" / "production"。
    /// 与 ``FlatRadar.entitlements`` 的 ``aps-environment`` 互相对应；
    /// 也是 ``/api/v1/devices/register`` 的 ``env`` 字段值。
    static var currentEnv: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// 硬件标识符。iOS 上是 "iPhone16,2" 这类机型串。
    /// 迁移前直接读 `utsname.machine`；那个值在 Mac 上是 CPU 架构不是机型，
    /// 所以改成由宿主注入，见 ``PlatformInfo/hardwareModel``。
    static var currentModel: String { PlatformEnvironment.info.hardwareModel }

    /// 系统版本，如 "18.5"。随 `/devices/register` 一起上报。
    ///
    /// 为什么要报
    /// ----------
    /// App Store Connect 的 Analytics 已经给了系统版本的**聚合**分布，所以这里
    /// 报它不是为了看「有多少人在 iOS 18」——那个问题已经有免费答案了。
    ///
    /// 要的是**逐设备**的组合：`model` 报的是硬件标识符（iPhone16,2 这种），
    /// 加上系统版本，后端才能算出「机型够格 **且** 系统够新」的那批设备占多少。
    /// 这是端上模型（Foundation Models）三道门里的前两道，ASC 的聚合报表拼不出来
    /// ——它给的是两张互相独立的分布，不是交叉表。
    ///
    /// 第三道门「用户有没有开 Apple Intelligence」这里还报不了，那要读
    /// `SystemLanguageModel.default.availability`，需要 iOS 26 SDK。见 docs/NEXT.md。
    static var currentOSVersion: String { PlatformEnvironment.info.systemVersion }

    static var currentBundleId: String {
        Bundle.main.bundleIdentifier ?? ""
    }

    /// 设备当前语言，取 primary language code（"en" / "zh" / ...）。
    /// 上报给后端的 ``/api/v1/devices/register``，用于 APNs 双语推送。
    ///
    /// 曾经带一个 `if #available(iOS 16, *)` 的分支，回退到已废弃的
    /// `Locale.current.languageCode`。最低支持版本升到 18.0 之后那条分支
    /// 永远不会执行，连同它里面那个废弃 API 一起删掉。
    static var currentLanguage: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    // MARK: - Setup

    /// App 启动时调一次：挂回调，让 PushDelegate 把 token 转给我们。
    public func setup(bridge: any PushPlatformBridge) {
        guard !hasInstalledDelegate else { return }
        hasInstalledDelegate = true
        self.bridge = bridge
        bridge.onDeviceToken = { [weak self] data in
            Task { @MainActor in
                await self?.handleDeviceToken(data)
            }
        }
        bridge.onRegistrationError = { [weak self] err in
            Task { @MainActor in
                self?.lastError = err.localizedDescription
                print("[PushStore] registration error: \(err)")
            }
        }
        // ⚠️ 时序救援：iOS 可能在 setup() 前就调过 didRegister（cached token
        // 重放），那时 onDeviceToken 还是 nil 把 token 丢了。这里挂完回调
        // 立刻让 delegate 把缓存 token 重发一次。
        bridge.flushPendingToken()
        Task { await refreshPermissionStatus() }
    }

    // MARK: - Permission + register

    /// 登录成功后调：弹通知权限框 + APNs 注册。
    /// guest 角色不应调（没 token 调不通 ``/devices/register``）。
    public func requestPermissionAndRegister() async {
        // 截图自动化下**不弹**系统权限框。
        //
        // 它是一个系统 alert，会盖在界面正中间，而带系统弹窗的截图不能上架
        // App Store。2026-09-04 的那批产出里，每种语言的 01-Dashboard 与
        // 02-Listings 都被它挡住——测试全过、尺寸全对，图却不能用。
        //
        // 拦在这里而不是逐个调用点：这个方法有六处调用（App 启动、登录、注册、
        // 设置页重新注册…），漏掉任何一处，弹窗就会在某张截图上重新出现。
        guard !UITestFlags.isScreenshotMode else {
            #if DEBUG
            print("[PushStore] 截图模式，跳过通知权限申请")
            #endif
            return
        }
        // 用户自己关掉的推送，任何自动路径都不许替他打开。
        //
        // 拦在这里而不是逐个调用点：这个方法有六处调用（App 启动、登录、
        // 注册转正、Mac 的 `.task(id:)`…），漏掉任何一处，那条路就会把用户
        // 关掉的通知重新注册回来——原先的 bug 正是冷启动那一处。
        // 用户重新打开走 ``setEnabled(true)``，它会先把这个意愿清掉。
        guard !deliveryDisabledByUser else {
            print("[PushStore] 用户已关闭推送，跳过注册")
            return
        }
        do {
            let granted = try await notifications.requestAuthorization(
                options: [.alert, .badge, .sound])
            print("[PushStore] requestAuthorization granted=\(granted)")
        } catch {
            lastError = error.localizedDescription
            print("[PushStore] requestAuthorization error: \(error)")
            // **拒过之后再请求，macOS 不是返回 false，而是直接抛错。**
            //
            // iOS 上用户拒绝后，`requestAuthorization` 返回 `granted=false`，
            // 流程往下走到 `refreshPermissionStatus()`，状态自然变成 `.denied`。
            // macOS 上同样的情况抛 `UNError.notificationsNotAllowed`（Code=1，
            // "Notifications are not allowed for this application"），原先这里
            // 直接 return，`permissionStatus` 就停在 `.notDetermined`——宿主看到的
            // 是「还没问过」，而实际是「问过了、被拒了、系统不会再弹」。
            //
            // 2026-09-16 在 Mac 上实测踩到：权限横幅被拖走即视为拒绝，之后每次
            // 启动都是这个错，界面上毫无表示。
            await refreshPermissionStatus()
            if Self.isNotAllowed(error) { permissionStatus = .denied }
            return
        }
        await refreshPermissionStatus()
        guard permissionStatus == .authorized
            || permissionStatus == .provisional
            || permissionStatus == .ephemeral else {
            print("[PushStore] permission not granted, skip APNs register")
            return
        }
        // 触发 APNs 注册；token 异步回到桥接层的 onDeviceToken
        bridge?.registerForRemoteNotifications()
    }

    /// 重新读一次系统里的通知权限。
    ///
    /// 用户随时可能去系统设置里改——宿主在「从系统设置切回来」、打开设置页这类时刻
    /// 调一次，界面上显示的状态才不会是几分钟前的。
    public func refreshPermissionStatus() async {
        permissionStatus = Self.map(await notifications.authorizationStatus())
    }

    /// 返回前台或进入设置时重新读取系统授权；不再次弹出权限申请。
    /// 在 await 后检查会话，避免查询期间退出登录仍启动设备注册。
    public func refreshPermissionAndRegistration(canRegister: () -> Bool) async {
        await refreshPermissionStatus()
        guard !Task.isCancelled, canRegister(), !deliveryDisabledByUser,
              !UITestFlags.isScreenshotMode,
              permissionStatus == .authorized || permissionStatus == .provisional
                || permissionStatus == .ephemeral else { return }
        bridge?.registerForRemoteNotifications()
    }

    /// 这个错误是不是「系统不允许这个 app 发通知」——也就是用户拒过、系统不会再弹框。
    static func isNotAllowed(_ error: any Error) -> Bool {
        (error as? UNError)?.code == .notificationsNotAllowed
    }

    private static func map(_ s: UNAuthorizationStatus) -> PermissionStatus {
        switch s {
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .authorized:    return .authorized
        case .provisional:   return .provisional
        // `UNAuthorizationStatusEphemeral` 在 macOS SDK 里标了
        // API_UNAVAILABLE(macos)，只能在 iOS 上匹配。App Clip 专用状态，
        // Mac 上不存在对应概念，落到 @unknown default 即可。
        #if os(iOS)
        case .ephemeral:     return .ephemeral
        #endif
        @unknown default:    return .notDetermined
        }
    }

    // MARK: - Device token → backend

    /// PushDelegate 转发的 device token，写库 + 上报。
    func handleDeviceToken(_ data: Data) async {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        print("[PushStore] APNs token hex \(hex.prefix(12))… (\(hex.count) chars)")
        lastToken = hex

        // 第二道同样的门。``requestPermissionAndRegister`` 那道拦不住这里：
        // token 是**异步**回来的，而且 ``setup()`` 里的 `flushPendingToken()`
        // 会无条件重放缓存 token。所以「关掉开关的同时上一次注册的 token 正在
        // 路上」会绕过前一道门，直接把设备注册回后端——界面上开关是关的，推送
        // 却照收。
        guard !deliveryDisabledByUser else {
            print("[PushStore] 用户已关闭推送，丢弃这次 token 上报")
            return
        }

        // APNs token 是异步到达的。如果它在 requestPermissionAndRegister 后到
        // 但用户已经登出（auth token 已清），此时调 /devices/register 会要么
        // 401 要么把 token 错误地绑到没有 bearer 的请求上。守一道门：没 token
        // 就先存 `lastToken`、等下次 setup() 再注册（PushDelegate.shared 仍持有）。
        guard client.currentToken() != nil else {
            print("[PushStore] no auth token, defer device registration until login")
            return
        }

        do {
            let resp = try await client.registerDevice(
                token: hex,
                env: Self.currentEnv,
                model: Self.currentModel,
                bundleId: Self.currentBundleId,
                language: Self.currentLanguage,
                osVersion: Self.currentOSVersion)
            registeredDeviceId = resp.deviceId
            lastError = nil
            print("[PushStore] backend registered device_id=\(resp.deviceId) env=\(resp.env)")
        } catch {
            lastError = error.localizedDescription
            print("[PushStore] backend registerDevice failed: \(error)")
        }
    }

    // MARK: - Logout

    /// 登出时删除当前会话的设备绑定；APNs token 本身保留（同设备重登可复用）。
    public func logout() async {
        if let id = registeredDeviceId {
            _ = try? await client.deleteDevice(id: id)
        }
        registeredDeviceId = nil
        lastToken = nil
        lastError = nil
    }

    // MARK: - User-facing toggle

    /// 设置里 "Enable Notifications" 开关用：开 → 申请权限 + 注册；关 → 记下
    /// 用户的选择 + 删后端设备绑定。区别于 ``logout``：不清 lastToken /
    /// lastError，用户重新打开时可立即用现存 APNs token 再注册。
    ///
    /// **先写 ``deliveryDisabledByUser`` 再做网络动作**，两个方向都要：
    /// 关的时候先落盘，`deleteDevice` 慢或失败也不会让这次关闭丢掉；开的时候
    /// 先清掉，否则 ``requestPermissionAndRegister`` 会被上面那道门自己挡回去。
    public func setEnabled(_ enabled: Bool) async {
        setDeliveryDisabled(!enabled)
        if enabled {
            await requestPermissionAndRegister()
        } else {
            if let id = registeredDeviceId {
                _ = try? await client.deleteDevice(id: id)
            }
            registeredDeviceId = nil
        }
    }

    /// ``deliveryDisabledByUser`` 的唯一写入口：内存与 UserDefaults 一起改。
    ///
    /// 不写成属性的 `didSet`：`@Observable` 宏会把存储属性改写成带
    /// `withMutation` 的计算属性，属性观察器在这套改写下不可靠，落盘可能整个
    /// 丢掉——而丢掉正好就是这次要修的 bug。
    private func setDeliveryDisabled(_ disabled: Bool) {
        deliveryDisabledByUser = disabled
        defaults.set(disabled, forKey: Self.deliveryDisabledKey)
    }
}
