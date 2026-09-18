import XCTest
@testable import FlatRadar

@MainActor
final class BrowseStateTests: XCTestCase {
    func testDetailSurvivesRepeatedWidthChangesAndBackNavigation() {
        for (tab, mode) in [(AppTab.listings, BrowseMode.list), (.map, .map), (.calendar, .calendar)] {
            let coord = NavigationCoordinator()
            coord.selectedTab = tab
            coord.normalizeSelection(tab, compact: false)
            coord.listingsPath = [.byId("list-old", titleHint: nil)]
            coord.mapPath = [.byId("map-old", titleHint: nil)]
            coord.calendarPath = [.byId("calendar-old", titleHint: nil)]
            coord.showListing(id: "current")
            let expected = coord.currentStack
            for _ in 0..<3 {
                coord.normalizeSelection(coord.selectedTab, compact: true)
                XCTAssertEqual(coord.selectedTab, .browse)
                XCTAssertEqual(coord.selectedBrowseMode, mode)
                XCTAssertEqual(coord.browsePath.last, .byId("current", titleHint: nil))
                XCTAssertEqual(coord.browsePath.count, 2)
                coord.normalizeSelection(coord.selectedTab, compact: false)
                XCTAssertEqual(coord.selectedTab, tab)
                XCTAssertEqual(coord.currentStack, expected)
            }
            coord.normalizeSelection(coord.selectedTab, compact: true)
            coord.browsePath.removeLast()
            coord.normalizeSelection(coord.selectedTab, compact: false)
            XCTAssertEqual(coord.browsePath.count, 1)
            // 其它模式的历史详情没有被迁移覆盖。
            XCTAssertEqual(coord.listingsPath.first, .byId("list-old", titleHint: nil))
            XCTAssertEqual(coord.mapPath.first, .byId("map-old", titleHint: nil))
            XCTAssertEqual(coord.calendarPath.first, .byId("calendar-old", titleHint: nil))
        }
    }

    func testCompactMapAndCalendarPushIntoTheirOwnPaths() {
        let coord = NavigationCoordinator()
        coord.selectedTab = .browse
        for mode in [BrowseMode.map, .calendar] {
            coord.selectedBrowseMode = mode
            coord.showListing(id: mode.rawValue)
            XCTAssertEqual(coord.browsePath, [.byId(mode.rawValue, titleHint: nil)])
        }
        XCTAssertTrue(coord.listingsPath.isEmpty)
    }

    func testFiltersSurviveModeChangesAndResetWithSession() {
        let coord = NavigationCoordinator()
        let state = coord.listingsState
        state.searchText = "canal"
        state.searchDraft = "canal house"
        state.selectedCities = ["Amsterdam"]
        state.sort = .priceLow
        coord.selectedTab = .browse
        for mode in BrowseMode.allCases {
            coord.selectedBrowseMode = mode
            coord.normalizeSelection(coord.selectedTab, compact: false)
            coord.normalizeSelection(coord.selectedTab, compact: true)
            XCTAssertTrue(coord.listingsState === state)
            XCTAssertEqual(coord.listingsState.searchText, "canal")
            XCTAssertEqual(coord.listingsState.selectedCities, ["Amsterdam"])
            XCTAssertEqual(coord.listingsState.sort, .priceLow)
        }
        coord.reset()
        XCTAssertFalse(coord.listingsState === state)
        XCTAssertEqual(coord.listingsState.searchText, "")
        XCTAssertTrue(coord.listingsState.selectedCities.isEmpty)
        XCTAssertEqual(coord.listingsState.sort, .newest)
    }
}
