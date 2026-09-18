//
//  MacReviewFlowUITests.swift
//  FlatRadarMacUITests
//
//  代码审查里"只有真点一遍才知道"的那类问题的端到端守卫。
//
//  规则本身在 FlatRadarMacTests 里有单测（`MapPaneStateTests`），但地图零结果那条
//  问题的本质是**界面上的入口在不在**：筛到零条时筛选按钮还能不能点到。单测证明
//  不了一个按钮在屏幕上。
//
//  ⌘R 菜单项的标题（Reload Map…）没有放在这里验：菜单命令读的是 key window 的
//  focusedSceneValue，而 XCUITest 在一台正被使用的 Mac 上拿不到前台（实测
//  `app.activate()` 之后最前面的仍是 Finder），读出来的菜单项全是灰的、标题是空值
//  时的 "Reload"——验的是环境不是代码。那条由 `SectionReloadTests` 和
//  tests/test_mac_reload_and_routes_wiring.py 守。
//
//  依赖线上的 `/map` 数据。拿不到数据时跳过，不判失败——那说明的是网络，不是这里的问题。
//

import XCTest

@MainActor
final class MacReviewFlowUITests: XCTestCase {

    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        // 同 `MacScreenshotTests`：等进程真的退出，下一条才不会拿到一个没窗口的旧实例。
        app.terminate()
        let deadline = Date().addingTimeInterval(10)
        while app.state != .notRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func launch(section: String) {
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES",
                               "-UI_TEST_SCREENSHOT_MODE", "1",
                               "-UI_TEST_SECTION", section]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 60), "主窗口没出来")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pane-\(section)")
                        .firstMatch.waitForExistence(timeout: 30), "没落到「\(section)」屏")
    }

    /// 地图筛到零条之后，筛选入口还在，而且能撤销（代码审查 P2）。
    ///
    /// 原先零结果时整屏换成空状态，「All filters」、筛选 token、Reset 全长在地图的
    /// 浮层上，跟着一起没了——筛选却还在，切屏回来还是那张空卡。
    func test_地图筛到零条_筛选入口还在_能撤销() throws {
        launch(section: "map")
        let allFilters = app.buttons["All filters"]
        guard allFilters.waitForExistence(timeout: 30) else {
            throw XCTSkip("地图没加载出来（网络 / 数据），这条验不了")
        }

        // 把状态档全关掉：一套都放不过。
        allFilters.click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "筛选浮层没弹出来")
        let toggles = popover.checkBoxes.allElementsBoundByIndex
            + popover.switches.allElementsBoundByIndex
        XCTAssertFalse(toggles.isEmpty, "浮层里找不到状态开关")
        for toggle in toggles where (toggle.value as? Int) == 1 || (toggle.value as? String) == "1" {
            toggle.click()
        }
        popover.buttons["Done"].click()

        let card = app.staticTexts["No listings match these filters"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "筛到零条时应该出说明卡")
        XCTAssertTrue(allFilters.exists && allFilters.isHittable,
                      "零结果时「All filters」必须还在、还点得到——这正是原先丢掉的入口")

        // 卡上的 Reset Filters 能把人带出来。
        app.buttons["Reset Filters"].click()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "重置之后说明卡应该消失")
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while exists, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        return !exists
    }
}
