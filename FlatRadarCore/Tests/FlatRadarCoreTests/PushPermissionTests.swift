import XCTest
import UserNotifications
@testable import FlatRadarCore

/// 「用户拒过通知」这个状态怎么识别。
///
/// macOS 上拒过之后再调 `requestAuthorization`，**不返回 false，而是抛错**：
///
///     Error Domain=UNErrorDomain Code=1
///     "Notifications are not allowed for this application"
///
/// iOS 上同样的情况是返回 `granted=false`。`PushStore` 原先只按 iOS 的方式处理，
/// catch 分支直接 return，于是 Mac 上 `permissionStatus` 永远停在 `.notDetermined`，
/// 宿主根本没法判断「该不该提示用户去系统设置打开」。
/// 2026-09-16 实测：权限横幅被拖走即视为拒绝，此后每次启动都是这个错。
final class PushPermissionTests: XCTestCase {

    @MainActor
    func test_UNErrorCode1识别为不允许() {
        XCTAssertTrue(PushStore.isNotAllowed(UNError(.notificationsNotAllowed)))
    }

    /// 真机上拿到的是 NSError（桥接过来的），不是 Swift 的 `UNError` 值——
    /// 按 domain + code 构造一个，确保 `as? UNError` 这条桥接走得通。
    @MainActor
    func test_桥接来的NSError也能识别() {
        let raw = NSError(domain: UNErrorDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Notifications are not allowed for this application"])
        XCTAssertTrue(PushStore.isNotAllowed(raw))
    }

    /// 别的通知错误（附件无效、请求太多…）不是「用户拒了」，不能弹去系统设置的窗。
    @MainActor
    func test_其它错误不算不允许() {
        XCTAssertFalse(PushStore.isNotAllowed(UNError(.attachmentInvalidURL)))
        XCTAssertFalse(PushStore.isNotAllowed(URLError(.notConnectedToInternet)))
        XCTAssertFalse(PushStore.isNotAllowed(NSError(domain: UNErrorDomain, code: 100)))
    }
}
