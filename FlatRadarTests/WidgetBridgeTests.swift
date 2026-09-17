import XCTest
import FlatRadarCore
@testable import FlatRadar

/// App Group 那一半，iOS 这一端——**只有跑在带 entitlement 的进程里才测得出来**。
///
/// 和 `FlatRadarMacTests/WidgetBridgeTests` 是同一件事的两端，各留一份是必要的：
/// 两端的组名写法**不一样**（iOS `group.com.j.kong.FlatRadar`，macOS 必须带
/// team 前缀），描述文件也是两套。Mac 那边通了不代表这边通。
///
/// 而它只会以静默的方式坏掉：组名写错一个字符、entitlements 少一条、
/// 或者 App ID 上压根没开 App Groups——三种都不报错，容器写不进去，
/// 小组件只是永远显示空。
@MainActor
final class WidgetBridgeTests: XCTestCase {

    /// 这几条读写的是**真实的**共享容器，也就是主屏上那几格正在用的那份数据。
    /// 跑完原样放回去，免得在自己手机上跑一次测试就把小组件清空了。
    private var saved: WidgetSnapshot?

    override func setUp() {
        super.setUp()
        saved = WidgetBridge.read()
        WidgetBridge.clear()
    }

    override func tearDown() {
        if let saved { WidgetBridge.publish(saved) } else { WidgetBridge.clear() }
        super.tearDown()
    }

    private func sample(_ captured: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(newToday: 31,
                       dailyNew: [14, 9, 22, 17, 11, 26, 19, 13, 8, 24, 20, 16, 12, 31],
                       totalListings: 831,
                       statusChanges: 47,
                       newThisWeek: 118,
                       matchCount: 193,
                       isFiltered: true,
                       unreadAlerts: 7,
                       showsUnread: true,
                       newest: [WidgetListing(id: "a", name: "Kastanjelaan 400",
                                              city: "Eindhoven", platform: "Holland2Stay",
                                              price: "€1,142",
                                              firstSeen: captured.ISO8601Format())],
                       unreadKinds: UnreadBreakdown(newListings: 3, statusChanges: 2, lottery: 2),
                       lastScrape: captured.addingTimeInterval(-60).ISO8601Format(),
                       capturedAt: captured)
    }

    /// 组名**不能**带 team 前缀。macOS 那边必须带，这边必须不带。
    ///
    /// 这一条是纯字符串检查，不碰容器——真正的通断由下面那条往返负责。
    func test_组名不带_team_前缀() {
        XCTAssertEqual(WidgetBridge.appGroup, "group.com.j.kong.FlatRadar")
    }

    /// 写进去读得出来，一个字段都不丢。**这条才是 entitlement 检查。**
    ///
    /// `containerURL(...)` 本身不核对签名（在 macOS 上实测过：组名写错它照样
    /// 返回一个路径），挡下来的是**写**那一步。所以往返成功才说明这条路通。
    func test_写进去再读出来是同一份() throws {
        let snap = sample()
        WidgetBridge.publish(snap)
        let back = try XCTUnwrap(
            WidgetBridge.read(),
            """
            刚写完就读不到 —— App Group \(WidgetBridge.appGroup) 没打通。
            三种可能，一种都不会报错：两份 entitlements（app / 小组件）里少了
            com.apple.security.application-groups；组名和 WidgetBridge.appGroup
            对不上；或者 App ID 上没开 App Groups 能力。
            """)
        XCTAssertEqual(back, snap)
    }

    /// 登出：清完就真的读不到了。匹配数和未读是账户数据，app 里清干净而主屏上
    /// 那一格还挂着上一个账号的数字，等于这条判据没做完。
    func test_清完就读不到() {
        WidgetBridge.publish(sample())
        XCTAssertNotNil(WidgetBridge.read())
        WidgetBridge.clear()
        XCTAssertNil(WidgetBridge.read())
    }
}
