import XCTest

/// 不启用截图模式：必须走正常的登录小窗口 → 主界面尺寸恢复路径。
@MainActor
final class MacLoginWindowUITests: XCTestCase {
    func testNormalSignInWindowCanEnterBrowser() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-AppleLanguages", "(en)",
            "-UI_TEST_SCREENSHOT_MODE", "0",
            "-UI_TEST_SHOW_LOGIN", "1",
            "-menuBarResident", "0",
        ]
        app.launch()
        defer { app.terminate() }
        let browse = app.buttons["Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 20))
        browse.click()
        let pane = app.descendants(matching: .any)
            .matching(identifier: "pane-listings").firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 20))
        // 列表、统计及默认选中详情会分批到达，不能只验主界面出现的第一帧。
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 1)
            XCTAssertNotEqual(app.state, .notRunning)
            XCTAssertTrue(pane.exists)
        }
    }
}
