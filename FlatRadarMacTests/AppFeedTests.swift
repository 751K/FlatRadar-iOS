import XCTest
import FlatRadarCore
@testable import FlatRadarMac

/// Phase 4 的完成判据里，能在单测里钉住的那几条。
///
/// docs/MACOS.md §7 写的是「Phase 3 / 4 验证 SSE 重连、**单连接约束**、
/// **多窗口互不覆盖**和统一登出」。重连要有后端，登出要有钥匙串，这两条留给手测；
/// 剩下两条是纯逻辑，正好是这个文件。
@MainActor
final class AppFeedTests: XCTestCase {

    // MARK: - 「登录恢复只执行一次」

    func testRestoreOnceRunsOnlyTheFirstTime() async {
        let feed = AppFeed()
        var calls = 0
        // 三个窗口先后出现，每个都会调一次。
        for _ in 0..<3 {
            await feed.restoreOnce { calls += 1 }
        }
        XCTAssertEqual(calls, 1,
                       "第二个窗口不能再恢复一次会话——风险 6 第一条")
    }

    func testRestoreOnceMarksDoneBeforeAwaiting() async {
        // 两个窗口**并发**出现时也只能跑一次。
        //
        // 这一条测的是 `didRestore = true` 写在 `await` **之前**：写在之后的话，
        // 第一次调用会在 await 处让出，第二次进来看到的仍是 false，两次都跑。
        // 冷启动时两个窗口一起恢复正是这个时序。
        let feed = AppFeed()
        let counter = Counter()
        async let a: Void = feed.restoreOnce { await counter.bump() }
        async let b: Void = feed.restoreOnce { await counter.bump() }
        _ = await (a, b)
        let n = await counter.value
        XCTAssertEqual(n, 1)
    }

    private actor Counter {
        private(set) var value = 0
        func bump() async {
            // 让出一次，制造"第一次还没返回，第二次就进来了"的时序。
            await Task.yield()
            value += 1
        }
    }

    // MARK: - 「每个会话最多一条通知流」

    func testStreamNeedsAuthentication() {
        XCTAssertFalse(AppFeed.wantsStream(authenticated: false, isGuest: false,
                                           contentWindows: 2, menuBarResident: true),
                       "没登录就不该有流，开几个窗口都一样")
    }

    func testGuestNeverStreams() {
        // 风险 6 原话：「游客始终不连接个人流」。
        XCTAssertFalse(AppFeed.wantsStream(authenticated: true, isGuest: true,
                                           contentWindows: 3, menuBarResident: true))
    }

    func testStreamsWhileAnyContentWindowIsOpen() {
        XCTAssertTrue(AppFeed.wantsStream(authenticated: true, isGuest: false,
                                          contentWindows: 1, menuBarResident: false))
        XCTAssertTrue(AppFeed.wantsStream(authenticated: true, isGuest: false,
                                          contentWindows: 5, menuBarResident: false))
    }

    func testStopsWhenLastWindowClosesWithoutMenuBar() {
        // 「最后一个窗口关闭且尚未启用菜单栏常驻时断流」。
        XCTAssertFalse(AppFeed.wantsStream(authenticated: true, isGuest: false,
                                           contentWindows: 0, menuBarResident: false))
    }

    func testMenuBarResidencyKeepsStreamWithoutWindows() {
        // 「Phase 4 启用菜单栏常驻后，没有内容窗口也可维持连接」。
        XCTAssertTrue(AppFeed.wantsStream(authenticated: true, isGuest: false,
                                          contentWindows: 0, menuBarResident: true))
    }

    // MARK: - 窗口计数

    func testWindowCountIsACountNotAFlag() {
        let feed = AppFeed()
        let auth = AuthStore()
        XCTAssertEqual(feed.contentWindows, 0)

        feed.windowAppeared(auth: auth)
        feed.windowAppeared(auth: auth)
        XCTAssertEqual(feed.contentWindows, 2)

        // 两个窗口关掉一个，流不能断——所以这里必须是 1，不是 0。
        feed.windowDisappeared(auth: auth)
        XCTAssertEqual(feed.contentWindows, 1)

        feed.windowDisappeared(auth: auth)
        XCTAssertEqual(feed.contentWindows, 0)
    }

    func testWindowCountNeverGoesNegative() {
        // SwiftUI 的 `onDisappear` 在登录态切换时可能比 `onAppear` 多跑一次
        // （`RootView` 会在 MainWindow 和 SignInPane 之间换）。计数掉到负数的话，
        // 之后再开一个窗口也到不了 1，流就再也连不上了。
        let feed = AppFeed()
        let auth = AuthStore()
        feed.windowDisappeared(auth: auth)
        feed.windowDisappeared(auth: auth)
        XCTAssertEqual(feed.contentWindows, 0)

        feed.windowAppeared(auth: auth)
        XCTAssertEqual(feed.contentWindows, 1, "多减的那几次不能欠着")
    }
}
