import XCTest
import FlatRadarCore
@testable import FlatRadarMac

/// 「两个窗口的选择与临时筛选互不覆盖」——Phase 4 完成判据的第一条。
///
/// 一个窗口 = 一个 ``BrowseModel``（`MainWindow` 的 `@State`）。所以"互不覆盖"
/// 在单测里就是：造两个 model，动一个，另一个不动。
///
/// 这看着像在测 Swift 的值语义，但它测的其实是**归属**：只要哪天有人把
/// `BrowseModel`、`ListingsStore` 或者查询状态改成 `static let` / 单例，
/// 这些断言就会红——而那正是 docs/MACOS.md 风险 6 明确禁止的
/// 「有查询状态的 `ListingsStore` 不直接作为全局单例共享」。
@MainActor
final class MultiWindowTests: XCTestCase {

    func testSelectionDoesNotLeakBetweenWindows() {
        let a = BrowseModel(), b = BrowseModel()
        a.focused = "listing-1"
        a.selection = ["listing-1", "listing-2"]

        XCTAssertNil(b.focused)
        XCTAssertTrue(b.selection.isEmpty)
    }

    func testTemporaryFiltersDoNotLeakBetweenWindows() {
        let a = BrowseModel(), b = BrowseModel()
        a.searchText = "Wilhelminaplein"
        a.query.cities = ["Amsterdam"]
        a.query.maxRent = 1500

        XCTAssertEqual(b.searchText, "")
        XCTAssertTrue(b.query.isEmpty)
        XCTAssertFalse(b.hasActiveFilters)
    }

    func testSectionIsPerWindow() {
        // 「命令作用于当前窗口」：⌘2 切的是聚焦那个窗口，另一个留在原地。
        let a = BrowseModel(), b = BrowseModel()
        a.section = .map
        XCTAssertEqual(b.section, .listings)
    }

    func testSortOrderIsPerWindow() {
        let a = BrowseModel(), b = BrowseModel()
        a.sortOrder = [ListingColumnComparator(key: .price, order: .forward)]
        XCTAssertEqual(b.sortOrder.first?.key, .firstSeen,
                       "另一个窗口的排序不该被带着走")
    }

    func testPinnedListIsPerWindow() {
        let a = BrowseModel(), b = BrowseModel()
        a.togglePin("listing-1")
        XCTAssertEqual(a.pinned, ["listing-1"])
        XCTAssertTrue(b.pinned.isEmpty)
    }

    func testListingsStoreIsNotShared() {
        // 直接盯住风险 6 那句「不直接作为全局单例共享」：两个 model 的 store
        // 必须是两个对象。
        let a = BrowseModel(), b = BrowseModel()
        XCTAssertFalse(a.listings === b.listings)
    }

    // MARK: - 「在地图上定位」

    func testLocateOnMapSwitchesSectionAndRecordsRequest() {
        let model = BrowseModel()
        model.locateOnMap(Self.listing(id: "abc"))

        XCTAssertEqual(model.section, .map)
        XCTAssertEqual(model.mapFocusRequest?.id, "abc")
    }

    func testLocateOnMapTwiceOnTheSameListingStillFires() {
        // 序号存在的理由：只存 id 的话，对同一套房点第二次「Show on Map」
        // 赋的是同一个值，`onChange` 不触发，地图不会再飞过去一次。
        let model = BrowseModel()
        let l = Self.listing(id: "abc")

        model.locateOnMap(l)
        let first = model.mapFocusRequest?.seq
        model.locateOnMap(l)
        let second = model.mapFocusRequest?.seq

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }

    func testMapFocusRequestClears() {
        let model = BrowseModel()
        model.locateOnMap(Self.listing(id: "abc"))
        model.clearMapFocusRequest()
        XCTAssertNil(model.mapFocusRequest,
                     "处理完不清的话，下次切回地图屏会再飞一次")
    }

    func testLocateOnMapSurvivesTheSectionDidSet() {
        // `section` 的 `didSet` 会在离开地图屏时清 `mapBuilding`。
        // `locateOnMap` 先切 section 再写请求，顺序反了的话请求会被那一轮
        // didSet 的连带清理吃掉——这条钉住顺序。
        let model = BrowseModel()
        model.section = .listings
        model.locateOnMap(Self.listing(id: "abc"))
        XCTAssertEqual(model.mapFocusRequest?.id, "abc")
    }

    // MARK: -

    private static func listing(id: String) -> Listing {
        let json = """
        {"id":"\(id)","name":"Test 1","status":"available","source":"holland2stay",
         "price_raw":"€1200","price_value":1200,"available_from":null,
         "features":[],"feature_map":{},"city":"Amsterdam","url":"https://example.com/\(id)",
         "first_seen":null,"last_seen":null}
        """
        return try! JSONDecoder().decode(Listing.self, from: Data(json.utf8))
    }
}
