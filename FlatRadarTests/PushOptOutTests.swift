import XCTest
@testable import FlatRadarCore

/// 「用户关掉的通知，app 不许自己打开回来」。
///
/// 原先的 bug
/// ----------
/// 设置页的开关读 `registeredDeviceId != nil`，关掉只调 `DELETE /devices/<id>`。
/// 「用户选择关掉」这件事没有任何地方记下来，而 `registeredDeviceId == nil`
/// 和「从没注册过」无法区分。于是下次冷启动 `FlatRadarApp` 照例对已登录非访客
/// 调 `requestPermissionAndRegister()`，设备注册回来，开关读回来是开的。
///
/// 这里钉死的是那条缺失的信息：``PushStore/deliveryDisabledByUser`` 要落盘、
/// 要能跨「启动」（用新 store 读同一份 defaults 模拟）活下来、并且要真的挡住
/// 通往 `/devices/register` 的**两条**路。
/// 放在 `FlatRadarTests` 而不是挨着代码的 `FlatRadarCoreTests`：CI 只跑
/// `-only-testing:FlatRadarTests`（见 .github/workflows/ios.yml），Core 那个
/// 包的用例一条都不跑。守着一个「悄悄把用户关掉的通知打开」的 bug，测试自己
/// 却不在 CI 里，等于没写。
final class PushOptOutTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PushOptOutTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 落盘与恢复

    @MainActor
    func test_全新设备默认没有关过推送() {
        XCTAssertFalse(PushStore(defaults: defaults).deliveryDisabledByUser)
    }

    @MainActor
    func test_关掉开关会落盘() async {
        let store = PushStore(defaults: defaults)
        await store.setEnabled(false)

        XCTAssertTrue(store.deliveryDisabledByUser)
        XCTAssertTrue(defaults.bool(forKey: PushStore.deliveryDisabledKey),
                      "只改内存不落盘的话，下次启动这个选择就没了——正是原先的 bug")
    }

    /// 核心回归：关掉 → 「重启」→ 还是关的。
    @MainActor
    func test_关掉之后重启仍然是关的() async {
        await PushStore(defaults: defaults).setEnabled(false)

        // 新实例 = 新一次冷启动，只能靠 UserDefaults 把选择带过来。
        let afterRelaunch = PushStore(defaults: defaults)
        XCTAssertTrue(afterRelaunch.deliveryDisabledByUser)
    }

    /// 这条要走 `requestPermissionAndRegister()`，那里面会碰
    /// `UNUserNotificationCenter.current()`——它需要一个真正的 app bundle。
    /// 放在 `FlatRadarTests`（宿主是 FlatRadar.app）里才跑得了；搁在 Core 的
    /// 裸 `swift test` 进程里会抛 `bundleProxyForCurrentProcess is nil`。
    @MainActor
    func test_重新打开会清掉这个选择() async {
        let store = PushStore(defaults: defaults)
        await store.setEnabled(false)
        await store.setEnabled(true)

        XCTAssertFalse(store.deliveryDisabledByUser)
        XCTAssertFalse(defaults.bool(forKey: PushStore.deliveryDisabledKey))
        XCTAssertFalse(PushStore(defaults: defaults).deliveryDisabledByUser,
                       "重新打开同样要跨启动生效")
    }

    /// 键名是 iOS 和 Mac 共用的一份，改名就是把老用户的选择丢掉（读不到旧键，
    /// 默认值 false = 推送重新打开）。钉住它，别人重构时至少会看见这条失败。
    func test_键名不变() {
        XCTAssertEqual(PushStore.deliveryDisabledKey, "pushDeliveryDisabledByUser")
    }

    // MARK: - 两条注册路径都被挡住

    /// 第一条：冷启动 / 登录 / 注册转正都走的 `requestPermissionAndRegister()`。
    ///
    /// 这里不碰系统权限框——`deliveryDisabledByUser` 那道门在方法最前面，被挡住
    /// 时整个方法是个 no-op，`permissionStatus` 连问都不会去问，停在初始值。
    @MainActor
    func test_关掉之后自动注册路径直接返回() async {
        let store = PushStore(defaults: defaults)
        await store.setEnabled(false)
        store.permissionStatus = .notDetermined

        await store.requestPermissionAndRegister()

        XCTAssertEqual(store.permissionStatus, .notDetermined,
                       "被挡住就不该去读系统权限状态，更不该弹框")
        XCTAssertNil(store.registeredDeviceId)
    }

    /// 第二条：APNs token 异步回来时走的 `handleDeviceToken`。
    ///
    /// `setup()` 里的 `flushPendingToken()` 会无条件重放缓存 token，所以这条路
    /// 不经过上面那道门。没有第二道 guard 的话，「关掉开关的同时上一次注册的
    /// token 正在路上」会把设备直接注册回后端。
    ///
    /// 这台机器上没有登录态（`currentToken()` 为 nil），所以这里断言的是
    /// 「没有把 deviceId 设回来」，而不是网络有没有发出去。
    @MainActor
    func test_关掉之后迟到的token不会注册回来() async {
        let store = PushStore(defaults: defaults)
        await store.setEnabled(false)

        await store.handleDeviceToken(Data([0xDE, 0xAD, 0xBE, 0xEF]))

        XCTAssertNil(store.registeredDeviceId)
    }

    // MARK: - 别的路径不许顺手清掉这个选择

    /// 登出不清：通知权限是这台设备的，不是账号的。换个账号登进来，这台设备上
    /// 「我不要推送」依然算数。
    @MainActor
    func test_登出不清掉这个选择() async {
        let store = PushStore(defaults: defaults)
        await store.setEnabled(false)

        await store.logout()

        XCTAssertTrue(store.deliveryDisabledByUser)
        XCTAssertTrue(defaults.bool(forKey: PushStore.deliveryDisabledKey))
    }
}
