import AppKit
import SwiftUI
import FlatRadarCore
import XCTest
@testable import FlatRadarMac

@MainActor
final class WindowSizingTests: XCTestCase {
    func testMainWindowLayoutStaysBoundedDuringLoginAndResize() async throws {
        let window = window(size: WindowSizeTransition.signInSize)
        defer { window.close() }
        let host = NSHostingView(rootView: MainWindow()
            .environment(AuthStore())
            .environment(AppFeed())
            .environment(RouteInbox()))
        window.contentView = host
        window.orderFront(nil)
        // 覆盖报告中的 1022pt、登录窗口 900pt，以及常见的窄屏与正常尺寸。
        for width: CGFloat in [900, 1022, 1280, 1440, 900] {
            window.setContentSize(NSSize(width: width, height: 620))
            try await Task.sleep(for: .milliseconds(200))
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, 1022,
                                     "主界面必须能在崩溃报告中的宽度稳定布局")
            // AppKit 可以把 900pt 的登录窗口扩大到三栏最小尺寸，但不能反复变化。
            XCTAssertEqual(contentSize(window).width, max(width, host.fittingSize.width),
                           accuracy: 1)
        }
    }

    private func window(size: NSSize = NSSize(width: 1180, height: 760)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "WindowSizingTests")
        return window
    }

    private func contentSize(_ window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    func testRepeatedLoginUpdatesDoNotOverwriteBrowserSize() {
        let window = window()
        defer { window.close() }
        let original = contentSize(window)
        let transition = WindowSizeTransition()
        transition.apply(.signIn, to: window)
        XCTAssertEqual(contentSize(window), WindowSizeTransition.signInSize)
        XCTAssertNotEqual(window.contentLayoutRect.size, contentSize(window),
                          "真实带工具栏窗口的 layoutRect 与 setContentSize 使用的尺寸不同")
        for _ in 0..<20 { transition.apply(.signIn, to: window) }
        transition.apply(.browser, to: window)
        XCTAssertEqual(contentSize(window), original)
    }

    func testRestoringAndColdAuthenticatedLaunchKeepWindowSize() {
        let window = window()
        defer { window.close() }
        let original = contentSize(window)
        let transition = WindowSizeTransition()
        transition.apply(.restoring, to: window)
        XCTAssertEqual(contentSize(window), original)
        transition.apply(.browser, to: window)
        XCTAssertEqual(contentSize(window), original)
    }

    func testManualResizeIsPreservedAcrossRepeatedUpdatesAndNextLogin() {
        let window = window()
        defer { window.close() }
        let transition = WindowSizeTransition()
        transition.apply(.signIn, to: window)
        transition.apply(.browser, to: window)
        let resized = NSSize(width: 1100, height: 700)
        window.setContentSize(resized)
        transition.apply(.browser, to: window)
        XCTAssertEqual(contentSize(window), resized)
        transition.apply(.signIn, to: window)
        transition.apply(.browser, to: window)
        XCTAssertEqual(contentSize(window), resized)
    }

    func testLaunchFromSavedLoginSizeExpandsOnLogin() {
        let window = window(size: WindowSizeTransition.signInSize)
        defer { window.close() }
        let transition = WindowSizeTransition()
        transition.apply(.signIn, to: window)
        transition.apply(.browser, to: window)
        XCTAssertGreaterThan(contentSize(window).width, WindowSizeTransition.signInSize.width)
    }

    func testWindowAttachmentAppliesLatestPhaseInsteadOfStaleLoginRequest() async throws {
        let window = window()
        defer { window.close() }
        let original = contentSize(window)
        let view = WindowSizer.SizingView()
        view.phase = .signIn
        view.scheduleResize()
        view.phase = .browser
        window.contentView = view
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(contentSize(window), original)
    }

    func testLoginSizingRetriesWhenViewAttachesAfterInitialUpdate() async throws {
        let view = WindowSizer.SizingView()
        view.phase = .signIn
        view.scheduleResize()
        try await Task.sleep(for: .milliseconds(50))
        let window = window()
        defer { window.close() }
        window.contentView = view
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(contentSize(window), WindowSizeTransition.signInSize)
        view.phase = .browser
        view.scheduleResize()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(contentSize(window), NSSize(width: 1180, height: 760))
    }
}
