import XCTest
import FlatRadarCore
@testable import FlatRadarMac

/// 窗口级状态的逻辑。
///
/// 这些是 Phase 2 完成判据里**能自动验**的那部分：固定比较的替换规则、
/// 筛选框的匹配范围、列头排序到服务端参数的换算。键盘浏览和并排布局要人看，
/// 但这几条不该靠人记得点一遍。
final class BrowseModelTests: XCTestCase {

    /// `Listing` 只有 `init(from:)`，没有逐成员构造器——它是纯解码类型。
    /// 造测试数据就得走 JSON，这也顺带验了解码本身。
    private func listing(id: String, name: String = "Somestraat 1",
                         city: String = "Eindhoven",
                         building: String? = nil) throws -> Listing {
        var fm: [String: String] = ["area": "50 m²"]
        if let building { fm["building"] = building }
        let dict: [String: Any] = [
            "id": id, "name": name, "status": "Available to book",
            "source": "holland2stay", "price_raw": "€1,200", "price_value": 1200.0,
            "available_from": "2026-10-01", "city": city, "url": "https://example.invalid/\(id)",
            "features": [], "feature_map": fm,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(Listing.self, from: data)
    }

    // MARK: - 固定比较

    @MainActor
    func testPinTogglesOff() {
        let m = BrowseModel()
        m.togglePin("a")
        XCTAssertEqual(m.pinned, ["a"])
        m.togglePin("a")
        XCTAssertTrue(m.pinned.isEmpty)
    }

    /// 满两个再固定第三个 → 挤掉**最早**那个，不是最新那个。
    ///
    /// 挤掉最新的话，用户点第三套时会发现刚点的没进去，像是没反应。
    @MainActor
    func testPinningAThirdReplacesTheOldest() {
        let m = BrowseModel()
        m.togglePin("a"); m.togglePin("b"); m.togglePin("c")
        XCTAssertEqual(m.pinned, ["b", "c"])
    }

    @MainActor
    func testUnpinningTheMiddleKeepsTheOther() {
        let m = BrowseModel()
        m.togglePin("a"); m.togglePin("b")
        m.togglePin("a")
        XCTAssertEqual(m.pinned, ["b"])
    }

    /// 固定项在数据里找不到时返回 nil，**不能**顺移成别的房源。
    /// 界面据此显示 "No longer available"。
    @MainActor
    func testPinnedListingIsNilWhenGone() {
        let m = BrowseModel()
        m.togglePin("ghost")
        let entries = m.pinnedListings
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "ghost")
        XCTAssertNil(entries[0].listing)
    }

    // MARK: - 列头排序 → 服务端参数

    func testColumnComparatorMapsToServerSort() {
        XCTAssertEqual(
            ListingColumnComparator(key: .price, order: .forward).serverSort.wireValue,
            "price")
        XCTAssertEqual(
            ListingColumnComparator(key: .price, order: .reverse).serverSort.wireValue,
            "-price")
    }

    /// 这个 comparator 是**标签不是算法**：排序由服务端做，本地比较必须是恒等的。
    /// 一旦有人把它改成"真比较"，点列头会先本地排一遍已加载的、再被服务端结果
    /// 覆盖，中间闪一下；分页没拉全时那次本地排序还是错的顺序。
    func testColumnComparatorDoesNotActuallySort() throws {
        let a = try listing(id: "a", name: "AAA")
        let b = try listing(id: "b", name: "ZZZ")
        let c = ListingColumnComparator(key: .price, order: .forward)
        XCTAssertEqual(c.compare(a, b), .orderedSame)
        XCTAssertEqual(c.compare(b, a), .orderedSame)
    }

    /// 默认排序必须与后端不传 `sort` 时的行为一致，否则首屏和点一下列头再点回来
    /// 会得到两种顺序。
    @MainActor
    func testDefaultSortMatchesServerDefault() {
        let m = BrowseModel()
        XCTAssertEqual(m.sortOrder.first?.serverSort.wireValue, "-first_seen")
    }
}
