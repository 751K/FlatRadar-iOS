import Foundation

/// 推送的**系统能力**桥接。各 app 实现，Core 只面向这个协议。
///
/// 为什么 Core 不能直接引用 delegate
/// --------------------------------
/// 迁移前 ``PushStore.setup()`` 直接写 `PushDelegate.shared`，而 `PushDelegate` 在
/// app 里、是 `UIApplicationDelegate`。这条反向引用是 Core 独立成模块时第一个断掉的
/// 东西，也是把它抽成协议的全部理由。macOS 的实现是 `NSApplicationDelegate`，
/// 签名对不上，但对 Core 而言只是"能拿到 token、能触发注册"。
///
/// ⚠️ 实现方注意：token 可能在 ``PushStore.setup()`` **之前**就由系统送达
/// （cached token 重放）。实现必须缓存这类早到的 token，并在 ``flushPendingToken()``
/// 被调用时重发一次，否则首次启动会丢 token。这是 iOS 端既有行为，不能在迁移里丢掉。
public protocol PushPlatformBridge: AnyObject {

    /// 系统送达 APNs device token。
    var onDeviceToken: ((Data) -> Void)? { get set }

    /// APNs 注册失败。
    var onRegistrationError: ((any Error) -> Void)? { get set }

    /// 把 ``onDeviceToken`` 挂上之前就到达的 token 重发一次。没有缓存时什么都不做。
    func flushPendingToken()

    /// 向 APNs 发起注册。iOS 是 `UIApplication.registerForRemoteNotifications()`，
    /// macOS 是 `NSApplication` 上的同名方法。
    func registerForRemoteNotifications()
}
