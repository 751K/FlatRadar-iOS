import Foundation
import UserNotifications

/// 通知权限这道系统门。
///
/// 为什么要抽出来
/// -------------
/// `UNUserNotificationCenter.requestAuthorization` 在权限还是 `.notDetermined`
/// 的机器上**弹一个系统框然后一直等人点**。没人点，`await` 就永不返回。
///
/// 这不是假设，是 CI 上实际发生的事：`test_重新打开会清掉这个选择` 走
/// ``PushStore/setEnabled(_:)`` → ``PushStore/requestPermissionAndRegister()``，
/// 在全新模拟器上停在这一句，从 14:29:03 一直挂到 30 分钟的 job 超时被杀。
/// 自 `3fde579` 起每一次推送都这样，而 Actions 上显示的是 `cancelled`，
/// 不是红叉——很容易被当成"网络抖了一下"。
///
/// **本地和真机都复现不出来**：那边权限早就问过了，`requestAuthorization` 读到
/// 一个已决定的状态立刻返回。也就是说这段代码只在**干净环境**里死，而干净环境
/// 正是 CI 的定义。
///
/// 所以抽这层不是"为了测试而抽象"——是这条路径在非交互环境里原本就没有走法。
/// 有了它，测试注入一个直接回答的替身，那道框根本不会弹。
///
/// `nonisolated`：包开了 `defaultIsolation(MainActor.self)`，不写的话协议要求会
/// 跟着跳主线程，而测试 target **没开**这个默认隔离（见 `Package.swift` 的注释），
/// 替身就得平白多一个 `@MainActor`。`UNUserNotificationCenter` 本来就是线程安全的。
public nonisolated protocol NotificationAuthorizing: Sendable {

    /// 申请通知权限。权限是 `.notDetermined` 时会弹系统框并等待用户。
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool

    /// 读当前权限状态。不弹框。
    func authorizationStatus() async -> UNAuthorizationStatus
}

/// 真的去问系统的那一份。宿主用的就是它。
public nonisolated struct SystemNotificationCenter: NotificationAuthorizing {

    public init() {}

    public func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
