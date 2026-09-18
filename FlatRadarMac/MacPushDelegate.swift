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

    // MARK: - 截图自动化

    /// 截图模式下**关掉最后一个窗口就退出**。
    ///
    /// macOS 的默认行为是不退出，这对真实用户是对的（⌘W 关窗口、⌘Q 才退出），
    /// 但它是截图套件里那个"跑着跑着就没窗口了"的根源：
    ///
    /// build 367 的六条用例里 00 和 01 过了、02–05 全挂在 `windows=0`。失败那几条
    /// 的屏幕录像是一张空桌面配一条 FlatRadarMac 菜单栏——**进程是活的，只是没有
    /// 窗口**。`XCUIApplication.terminate()` 之后进程若没真的死，下一条用例的
    /// `launch()` 拿到的就是这个没有窗口的现存实例，于是 60 秒等不到窗口。
    ///
    /// 只在截图模式下改，不动真实用户那边的行为。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        UITestFlags.isScreenshotMode
    }

    /// 被激活时没有窗口，就开一个。
    ///
    /// 上面那条是治本，这条是兜底：万一进程还是活到了下一条用例，激活它至少能
    /// 让 `WindowGroup` 补出一个窗口，而不是干等 60 秒。返回 true 就是让 AppKit
    /// 走它自己的"重开窗口"流程。
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        true
    }

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
    /// 投进 ``RouteInbox``，不再广播：原先 post 一次 `NotificationCenter` 就算完，
    /// 接收者在 `MainWindow` 里——关掉所有窗口只剩菜单栏时、冷启动窗口还没挂上时，
    /// 这次点击都没人接（代码审查 P2）。信箱会留着这条直到有窗口取走，没窗口就开一个。
    ///
    /// 回主线程再投：信箱是主 actor 的，这个回调不是（理由见上面那个 `willPresent`）。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in RouteInbox.shared.post(.alerts) }
        completionHandler()
    }
}
