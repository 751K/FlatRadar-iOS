import XCTest
import AppKit
import FlatRadarCore
@testable import FlatRadarMac

// MARK: - 通知对应的房源不在已加载列表里

/// 点某些通知，详情栏显示另一套房（代码审查 P2）。
///
/// 原先房源不在已加载那批里时 `focused` 保持不动：右栏上半是新通知，下半还是上一套房，
/// 工具栏钉住、⌘D、Open on Platform 也还作用在那套旧房上。
@MainActor
final class AlertFocusTests: XCTestCase {

    private func listing(_ id: String) throws -> Listing {
        let dict: [String: Any] = [
            "id": id, "name": "Somestraat \(id)", "status": "Available to book",
            "source": "holland2stay", "price_raw": "€1,200", "city": "Eindhoven",
            "url": "https://example.invalid/\(id)", "features": [], "feature_map": [:],
        ]
        return try JSONDecoder().decode(Listing.self,
                                        from: JSONSerialization.data(withJSONObject: dict))
    }

    private func alert(id: Int, listingID: String) -> AlertRow {
        AlertRow(id: id, date: nil, isRead: false, kind: .status, source: "holland2stay",
                 title: "Somestraat \(listingID)", summary: "Reserved → Book",
                 from: "Reserved", to: "Available to book", price: "€1,200",
                 listingID: listingID, url: "https://example.invalid/\(listingID)")
    }

    func test_通知的房源不在已加载那批里_详情焦点清空_不留着上一套() throws {
        let m = BrowseModel()
        m.listings.listings = [try listing("old")]
        m.focused = "old"                                  // 列表屏上选着的那套

        m.focusAlert(alert(id: 1, listingID: "not-loaded"))

        XCTAssertEqual(m.focusedAlert, 1)
        XCTAssertNil(m.focused, "上半说的是 not-loaded，下半和各种命令不能还指着 old")
    }

    func test_通知的房源在已加载那批里_详情焦点跟过去() throws {
        let m = BrowseModel()
        m.listings.listings = [try listing("old"), try listing("b")]
        m.focused = "old"

        m.focusAlert(alert(id: 2, listingID: "b"))

        XCTAssertEqual(m.focused, "b")
        XCTAssertEqual(m.focusedAlertRow?.listingID, "b")
    }

    func test_系统通知没有房源_焦点同样清空() throws {
        let m = BrowseModel()
        m.listings.listings = [try listing("old")]
        m.focused = "old"

        m.focusAlert(alert(id: 3, listingID: ""))

        XCTAssertNil(m.focused)
    }
}

// MARK: - 刷新按钮刷当前这一屏

/// 地图、日历、通知和统计页的刷新没有刷新当前页面（代码审查 P2）。
@MainActor
final class SectionReloadTests: XCTestCase {

    @MainActor final class Log {
        var calls: [String] = []
    }

    private func reloader(_ log: Log) -> SectionReloader {
        SectionReloader(
            listings: { log.calls.append("listings") },
            map: { log.calls.append("map") },
            calendar: { log.calls.append("calendar") },
            alerts: { log.calls.append("alerts") },
            stats: { log.calls.append("stats") },
            shared: { log.calls.append("shared") })
    }

    func test_每一屏刷的都是它自己_外加共享摘要() async {
        let expected: [SidebarSection: String] = [
            .listings: "listings", .map: "map", .calendar: "calendar",
            .alerts: "alerts", .stats: "stats",
        ]
        for section in SidebarSection.allCases {
            let log = Log()
            await reloader(log).reload(section)
            XCTAssertEqual(Set(log.calls), [expected[section]!, "shared"],
                           "\(section) 屏按刷新，刷到的是 \(log.calls)")
        }
    }

    func test_菜单项标题跟着当前屏走() {
        let action = SectionReloadAction(section: .map, isLoading: false, run: {})
        XCTAssertEqual(action.title, "Reload Map")
    }
}

// MARK: - 地图筛到零条

/// 地图筛选到零条结果后，无法撤销筛选（代码审查 P2）。
///
/// 原先零结果时整屏换成空状态，而筛选按钮、筛选 token、Reset 全长在地图的浮层里。
final class MapPaneStateTests: XCTestCase {

    func test_有房源但全被筛掉_地图照画_只是盖一张说明卡() {
        XCTAssertEqual(MapPaneState.resolve(isLoading: false, errorMessage: nil,
                                            hasListings: true, hasVisibleBuildings: false),
                       .map(filteredOut: true))
    }

    func test_正常情况就是地图() {
        XCTAssertEqual(MapPaneState.resolve(isLoading: false, errorMessage: nil,
                                            hasListings: true, hasVisibleBuildings: true),
                       .map(filteredOut: false))
    }

    func test_已有数据时_刷新中或刷新失败都继续画手上那批() {
        XCTAssertEqual(MapPaneState.resolve(isLoading: true, errorMessage: nil,
                                            hasListings: true, hasVisibleBuildings: true),
                       .map(filteredOut: false))
        XCTAssertEqual(MapPaneState.resolve(isLoading: false, errorMessage: "offline",
                                            hasListings: true, hasVisibleBuildings: false),
                       .map(filteredOut: true))
    }

    func test_还没有数据时才是整屏状态() {
        XCTAssertEqual(MapPaneState.resolve(isLoading: true, errorMessage: nil,
                                            hasListings: false, hasVisibleBuildings: false),
                       .loading)
        XCTAssertEqual(MapPaneState.resolve(isLoading: false, errorMessage: "offline",
                                            hasListings: false, hasVisibleBuildings: false),
                       .failed("offline"))
        XCTAssertEqual(MapPaneState.resolve(isLoading: false, errorMessage: nil,
                                            hasListings: false, hasVisibleBuildings: false),
                       .noCoordinates)
    }
}

// MARK: - 点系统通知的跳转

/// 没有内容窗口时，点击系统通知可能丢失跳转（代码审查 P2）。
///
/// 原先推送回调只广播一次 `NotificationCenter`，接收者在 `MainWindow` 里：没有窗口、
/// 或者窗口还没挂上时，没人接。
@MainActor
final class RouteInboxTests: XCTestCase {

    func test_没有窗口时投进来_会开一个窗口_窗口挂上之后取得到() {
        let inbox = RouteInbox()
        var opened = 0
        inbox.registerWindowOpener { opened += 1 }

        inbox.post(.alerts)
        XCTAssertEqual(opened, 1, "一个窗口都没有，得开一个")

        // 冷启动那条也是这样：窗口先出来、会话恢复完 `MainWindow` 才挂上来取。
        inbox.browserWindowAppeared()
        let (route, seq) = inbox.claim(after: 0, justAppeared: true)
        XCTAssertEqual(route, .alerts, "投进来时没人接，挂上之后必须还取得到")
        XCTAssertEqual(seq, 1)
    }

    func test_有窗口开着时不再开新的() {
        let inbox = RouteInbox()
        var opened = 0
        inbox.registerWindowOpener { opened += 1 }
        inbox.browserWindowAppeared()

        inbox.post(.locateOnMap(listingID: "a"))
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(inbox.claim(after: 0, justAppeared: false).route, .locateOnMap(listingID: "a"))
    }

    func test_已经被接过的_新开的窗口不会再执行一遍() {
        let inbox = RouteInbox()
        inbox.browserWindowAppeared()
        inbox.post(.alerts)
        XCTAssertEqual(inbox.claim(after: 0, justAppeared: false).route, .alerts)   // 开着的窗口接了

        // 十分钟后 ⌘N 开了个新窗口。
        let (route, seq) = inbox.claim(after: 0, justAppeared: true)
        XCTAssertNil(route, "新窗口不该把那次点击再执行一遍")
        XCTAssertEqual(seq, 1)
    }

    func test_开着的两个窗口都会跟过去_和原先的广播一致() {
        let inbox = RouteInbox()
        inbox.browserWindowAppeared(); inbox.browserWindowAppeared()
        inbox.post(.alerts)
        XCTAssertEqual(inbox.claim(after: 0, justAppeared: false).route, .alerts)
        XCTAssertEqual(inbox.claim(after: 0, justAppeared: false).route, .alerts)
    }

    func test_同一个窗口不会把同一条执行两次() {
        let inbox = RouteInbox()
        inbox.post(.alerts)
        let first = inbox.claim(after: 0, justAppeared: true)
        XCTAssertEqual(first.route, .alerts)
        XCTAssertNil(inbox.claim(after: first.seq, justAppeared: false).route)
    }

    func test_窗口全关了_再投_开得出窗口() {
        let inbox = RouteInbox()
        var opened = 0
        inbox.registerWindowOpener { opened += 1 }
        inbox.browserWindowAppeared()
        inbox.browserWindowDisappeared()                   // 只剩菜单栏

        inbox.post(.alerts)
        XCTAssertEqual(opened, 1)
    }

    // MARK: - 真的开得出窗口吗

    /// 登记进来的是 SwiftUI 的 `openWindow`。它是从**某个窗口**的环境里拿的——那个
    /// 窗口关掉之后，这个动作还能不能开出新窗口，决定了"只剩菜单栏时点通知"这条路
    /// 到底通不通。规则测试证明不了这件事，只能在真的 app 里试：测试宿主就是这个 app。
    func test_宿主里_关掉所有浏览窗口之后_投一条能开出新窗口() async throws {
        func browserWindows() -> [NSWindow] {
            NSApp.windows.filter {
                $0.isVisible && ($0.identifier?.rawValue.hasPrefix(FlatRadarMacApp.mainWindowID) ?? false)
            }
        }
        for _ in 0..<100 where browserWindows().isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard !browserWindows().isEmpty else {
            throw XCTSkip("测试宿主这次没开出主窗口（系统按零窗口恢复了），没有可关的")
        }
        let inbox = RouteInbox.shared
        for window in browserWindows() { window.close() }
        for _ in 0..<100 where inbox.browserWindows > 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(inbox.browserWindows, 0, "窗口关掉之后 RootView 应该报到离开")
        XCTAssertTrue(browserWindows().isEmpty)

        inbox.post(.alerts)

        for _ in 0..<100 where browserWindows().isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(browserWindows().isEmpty,
                       "开窗动作是从已经关掉的那个窗口登记的，它得照样开得出新窗口")
    }
}
