import XCTest
import FlatRadarCore
@testable import FlatRadarMac

/// App Group 那一半——**只有跑在带 entitlement 的进程里才测得出来**。
///
/// 为什么非得是这个 target：`WidgetBridge` 的每一条路都经过
/// `containerURL(forSecurityApplicationGroupIdentifier:)`，而那个调用只看
/// **签名里的 entitlement**。包的单元测试（`FlatRadarCoreTests`）是个裸的
/// xctest bundle，没有签，拿到的永远是 nil——在那边写这几条，会写出一组
/// 恒真的空转。这个 target 的 `TEST_HOST` 是 `FlatRadarMac.app`，跑在 app
/// 里面，entitlement 是真的。
///
/// 而这件事**只会以静默的方式坏掉**：组名写错一个字符、entitlements 少一条、
/// macOS 上忘了 team 前缀——三种都不报错，容器 URL 直接是 nil，小组件只是
/// 永远显示空。没有任何一条日志会告诉你原因。
final class WidgetBridgeTests: XCTestCase {

    /// 这几条读写的是**真实的**共享容器，也就是桌面上那一格正在用的那份数据。
    /// 跑完原样放回去，免得开发机上跑一次测试就把自己的小组件清空了。
    private var saved: WidgetSnapshot?

    override func setUp() {
        super.setUp()
        saved = WidgetBridge.read()
        WidgetBridge.clear()
    }

    override func tearDown() {
        if let saved {
            WidgetBridge.publish(saved)
        } else {
            WidgetBridge.clear()
        }
        super.tearDown()
    }

    private func sample(_ captured: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(matchCount: 193, isFiltered: true,
                       lastScrape: captured.addingTimeInterval(-240).ISO8601Format(),
                       newToday: 12, unreadAlerts: 3, showsUnread: true,
                       capturedAt: captured)
    }

    /// 容器路径的拼写。
    ///
    /// **这一条不是 entitlement 检查**，真去试过：把 `appGroup` 改成 iOS 那样的
    /// 裸 `group.com.j.kong.FlatRadar`（macOS 上是错的）再跑，这条照样过——
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` 在 macOS 上把路径
    /// 拼出来就返回了，不核对签名。挡下来的是**写**那一步，沙盒拒绝，
    /// 而 `WidgetBridge.write` 把错误咽掉只记日志，于是症状就是"读回来是 nil"。
    ///
    /// 所以真正钉住 entitlement 的是下面那条往返，这条只保证路径没拼歪。
    func test_容器路径是那个组名() throws {
        let url = try XCTUnwrap(WidgetBridge.containerURL)
        XCTAssertTrue(url.path.hasSuffix(WidgetBridge.appGroup),
                      "容器路径应当以组名结尾，实际是 \(url.path)")
    }

    /// 写进去读得出来，一个字段都不丢。
    ///
    /// **这条才是 entitlement 检查。** 组名写错一个字符、两份 entitlements 里
    /// 少一条、或者 macOS 上漏了 team 前缀——三种都会让写被沙盒拒掉，
    /// 于是这里读回 nil。实测过：把 `appGroup` 的 team 前缀去掉，
    /// 这个文件里五条挂三条，而上面那条路径检查毫无反应。
    func test_写进去再读出来是同一份() throws {
        let snap = sample()
        WidgetBridge.publish(snap)
        let back = try XCTUnwrap(
            WidgetBridge.read(),
            """
            刚写完就读不到 —— App Group \(WidgetBridge.appGroup) 没打通。
            三种可能，一种都不会报错：两份 entitlements 里少了
            com.apple.security.application-groups；组名和 WidgetBridge.appGroup
            对不上；或者 macOS 上漏了 team 前缀。
            """)
        XCTAssertEqual(back, snap)
    }

    /// 后写的盖掉先写的，不是追加，也不是两份并存。
    func test_后一次覆盖前一次() throws {
        WidgetBridge.publish(sample())
        var next = sample()
        next.matchCount = 7
        WidgetBridge.publish(next)
        XCTAssertEqual(WidgetBridge.read()?.matchCount, 7)
    }

    /// 登出：清完就真的读不到了。
    ///
    /// 匹配数和未读数是账户数据。窗口里清干净、桌面上那一格还挂着上一个账号的
    /// 数字，风险 6 那条判据就没做完——而且那一格比窗口显眼，登出之后还留在屏上。
    func test_清完就读不到() {
        WidgetBridge.publish(sample())
        XCTAssertNotNil(WidgetBridge.read())
        WidgetBridge.clear()
        XCTAssertNil(WidgetBridge.read(), "登出之后那一格还能读到上一个账号的数字")
    }

    /// 容器里空着的时候 `read()` 给 nil，不是崩，也不是一份全零的快照——
    /// 全零会被画成「匹配 0 套」，而事实是「还没有数据」。
    func test_没有文件时读到的是_nil_不是零() {
        WidgetBridge.clear()
        XCTAssertNil(WidgetBridge.read())
    }
}
