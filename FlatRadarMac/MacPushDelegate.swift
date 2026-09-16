import AppKit
import UserNotifications
import FlatRadarCore

/// macOS 的推送桥接：`NSApplicationDelegate` + `UNUserNotificationCenterDelegate`。
///
/// 对应 iOS 的 `FlatRadar/Push/PushDelegate.swift`。状态机在 Core 的 ``PushStore``
/// 里，两端共用；这里只做 Core 碰不到的那部分——拿 token、触发注册、接系统回调。
///
/// 为什么还是要一个 app delegate
/// ----------------------------
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` 是拿 APNs token
/// 的唯一途径，SwiftUI 没有对应的钩子。`@NSApplicationDelegateAdaptor` 把它挂进
/// App 生命周期。
///
/// 和 iOS 那份的两处差别
/// --------------------
/// 1. **没有 `static var shared`。** iOS 那边要它，是因为当年 `PushStore` 自己去拿
///    delegate；现在 `PushStore.setup(bridge:)` 由宿主直接把 adaptor 持有的那个实例
///    传进去，不存在「两个实例」的问题。
/// 2. **`UNUserNotificationCenterDelegate` 的两个回调是 `nonisolated`。**
///    见下面 `userNotificationCenter(_:willPresent:)` 的说明。
@MainActor
final class MacPushDelegate: NSObject, NSApplicationDelegate,
                             UNUserNotificationCenterDelegate, PushPlatformBridge {

    // MARK: - PushPlatformBridge

    var onDeviceToken: ((Data) -> Void)?
    var onRegistrationError: ((any Error) -> Void)?

    /// 系统可能在 ``PushStore/setup(bridge:)`` 挂上回调之前就送来 token
    /// （启动时的 cached token 重放）。先存着，``flushPendingToken()`` 时补发。
    private var latestDeviceToken: Data?

    func registerForRemoteNotifications() {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func flushPendingToken() {
        guard let data = latestDeviceToken else { return }
        onDeviceToken?(data)
    }

    // MARK: - NSApplicationDelegate

    /// AppKit 保证这几个在主线程上调，保持主 actor 隔离没问题。
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        latestDeviceToken = deviceToken
        #if DEBUG
        print("[MacPushDelegate] didRegister (\(deviceToken.count) bytes), handler=\(onDeviceToken != nil)")
        #endif
        onDeviceToken?(deviceToken)
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        #if DEBUG
        print("[MacPushDelegate] didFailToRegister: \(error)")
        #endif
        onRegistrationError?(error)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// App 在前台时也弹横幅——和 iOS 一致。不写的话系统会吞掉前台通知，
    /// 测试推送看起来就像没发出去。
    ///
    /// ⚠️ `nonisolated` 是故意的
    /// ------------------------
    /// 这个类是 `@MainActor`，不写 `nonisolated` 的话，编译器会给这两个 ObjC 回调
    /// 生成带主 actor 检查的 thunk。系统要是在自己的队列上回调，检查当场 trap——
    /// 2.1.0 线上的无限崩溃（MetricKit delegate）就是这么来的。iOS 上
    /// `UNUserNotificationCenter` 实测是在主线程回调的，但 macOS 上没有核实过，
    /// 不值得拿启动崩溃去赌。回调里本来也不碰任何主 actor 状态，只取一个字符串、
    /// 调完成回调，所以退出隔离没有代价。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// 用户点了通知：切到 Alerts 屏。
    ///
    /// 投递到主线程再 post——`.onReceive` 的闭包在 **post 的那条线程**上同步执行，
    /// 在后台线程 post 等于在后台改 SwiftUI 状态。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let listingID = response.notification.request.content.userInfo["listing_id"] as? String
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .flatRadarOpenAlerts,
                object: nil,
                userInfo: listingID.map { ["listing_id": $0] })
        }
        completionHandler()
    }
}

extension Notification.Name {
    /// 点了推送通知之后发。`userInfo["listing_id"]` 可能有，可能没有。
    ///
    /// 不和 iOS 共用 `flatRadarOpenListing` 这个名字：iOS 是直接打开那套房的详情，
    /// Mac 这边打开的是 Alerts 屏——语义不同，名字一样只会让人以为行为也一样。
    static let flatRadarOpenAlerts = Notification.Name("FlatRadarOpenAlerts")

    /// `h2smonitor://map/<id>` 点进来之后发。`userInfo["listing_id"]` 必有。
    ///
    /// 走通知中心而不是直接改 model：deep link 是在 `App` 那一层接到的
    /// （`.onOpenURL` 挂在 `RootView` 上），而 `BrowseModel` 是**窗口级**的，
    /// 场景那一层够不着。和上面那条是同一个理由。
    static let flatRadarLocateOnMap = Notification.Name("FlatRadarLocateOnMap")
}
