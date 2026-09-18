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

    // MARK: - 地图选中的楼盘

    /// 赋值不能递归。
    ///
    /// 第一版把「离开地图就清掉」写在了 `mapBuilding` 自己的 `didSet` 里：
    ///
    ///     var mapBuilding: MapBuilding? {
    ///         didSet { if section != .map { mapBuilding = nil } }
    ///     }
    ///
    /// `didSet` **每次赋值都触发，不管值变没变**，所以在里面给自己赋值就是
    /// 无限递归。实测栈爆到 20963 层 SIGSEGV。这条测试跑得完就说明没递归。
    @MainActor
    func testAssigningMapBuildingDoesNotRecurse() throws {
        let m = BrowseModel()
        m.section = .listings
        m.mapBuilding = try building(id: "b1")
        m.mapBuilding = nil
        m.mapBuilding = try building(id: "b2")
        XCTAssertEqual(m.mapBuilding?.units.first?.id, "b2",
                       "MapBuilding.id 是坐标键，要认房源得看 units")
    }

    /// 离开地图 → 选中的楼盘放掉。
    ///
    /// 否则回到列表点一条房源，右栏顶上还挂着地图那栋楼的单元列表。
    @MainActor
    func testLeavingMapClearsBuilding() throws {
        let m = BrowseModel()
        m.section = .map
        m.mapBuilding = try building(id: "b1")
        XCTAssertNotNil(m.mapBuilding)

        m.section = .listings
        XCTAssertNil(m.mapBuilding, "切走之后不该还留着")
    }

    /// 在地图内部换来换去不清。
    @MainActor
    func testStayingOnMapKeepsBuilding() throws {
        let m = BrowseModel()
        m.section = .map
        m.mapBuilding = try building(id: "b1")
        m.section = .map
        XCTAssertEqual(m.mapBuilding?.units.first?.id, "b1")
    }

    @MainActor
    private func building(id: String) throws -> MapBuilding {
        // ⚠️ `MapListing` 的合成解码器要求 `neighborhood` / `building` / `area`
        // 全部存在，而 openapi 里这三个都**不在 required 列表**里。
        // 少一个整个 `/map` 响应就解不出来、地图直接空掉——这条已经开了后台任务，
        // 这里先按解码器的实际要求把 fixture 填全。
        let dict: [String: Any] = [
            "id": id, "name": "Somestraat 1", "status": "Available to book",
            "source": "holland2stay", "price_raw": "€1,200", "city": "Eindhoven",
            "neighborhood": "", "building": "Vestide Tower", "area": "50 m²",
            "address": "Somestraat 1",
            "available_from": "2026-10-01",
            "url": "https://example.invalid/\(id)", "lat": 51.44, "lng": 5.47,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict)
        let listing = try JSONDecoder().decode(MapListing.self, from: data)
        return MapBuilding.group([listing])[0]
    }

    // MARK: - 键盘浏览
    //
    // 表格自己有焦点时 ↑↓ 由 NSTableView 处理，那部分不归我们测。这里测的是
    // `moveSelection` —— 焦点在搜索框、或者走 ⌘↑/⌘↓ 菜单命令时用的那条路径。

    @MainActor
    private func loaded(_ m: BrowseModel, _ items: [Listing]) {
        m.listings.listings = items
        m.listings.total = items.count
    }

    /// 还没有焦点时：↓ 落第一条，↑ 落最后一条。
    @MainActor
    func testMoveSelectionFromNothing() throws {
        let m = BrowseModel()
        loaded(m, [try listing(id: "a"), try listing(id: "b"), try listing(id: "c")])

        m.moveSelection(by: 1)
        XCTAssertEqual(m.focused, "a")

        m.focused = nil
        m.moveSelection(by: -1)
        XCTAssertEqual(m.focused, "c")
    }

    /// 到头停住，**不回绕**。
    ///
    /// 回绕的话按住 ↓ 想翻到底，结果又从头开始，人会失去"我在哪儿"的感觉。
    @MainActor
    func testMoveSelectionClampsAtBothEnds() throws {
        let m = BrowseModel()
        loaded(m, [try listing(id: "a"), try listing(id: "b")])

        m.focused = "b"
        m.moveSelection(by: 1)
        XCTAssertEqual(m.focused, "b", "已经在最后一条，↓ 不该回到第一条")

        m.focused = "a"
        m.moveSelection(by: -1)
        XCTAssertEqual(m.focused, "a", "已经在第一条，↑ 不该跳到最后一条")
    }

    /// **走的是筛选后可见的行，不是全部已加载的。**
    ///
    /// 这条是这组里最要紧的：拿全量算的话，↑↓ 会跳到一条屏幕上根本没有的房源，
    /// 右边详情变了、左边却没有任何东西高亮——看起来像界面坏了。
    @MainActor
    func testMoveSelectionWalksVisibleRowsOnly() async throws {
        let m = BrowseModel()
        loaded(m, [
            try listing(id: "a", name: "Kastanjelaan 1"),
            try listing(id: "b", name: "Vestdijk 2"),
            try listing(id: "c", name: "Kastanjelaan 3"),
        ])
        m.searchText = "kastanjelaan"
        await m.updateRows(debounce: false)
        XCTAssertEqual(m.rows.map(\.id), ["a", "c"], "前提：筛完只剩 a 和 c")

        m.focused = "a"
        m.moveSelection(by: 1)
        XCTAssertEqual(m.focused, "c", "应该跳过被筛掉的 b")

        m.moveSelection(by: 1)
        XCTAssertEqual(m.focused, "c", "c 是可见行里的最后一条")
    }

    /// 选中要跟着焦点走，否则表格上没有高亮行。
    @MainActor
    func testMoveSelectionKeepsSelectionInSync() throws {
        let m = BrowseModel()
        loaded(m, [try listing(id: "a"), try listing(id: "b")])
        m.moveSelection(by: 1)
        XCTAssertEqual(m.selection, ["a"])
        m.moveSelection(by: 1)
        XCTAssertEqual(m.selection, ["b"], "旧的要换掉，不是累加成多选")
    }

    /// 首屏必须自动选中第一条：否则 ↑↓ 没有起点，右边一直是 "No Selection"。
    @MainActor
    func testSelectFirstRowIfNeeded() throws {
        let m = BrowseModel()
        loaded(m, [try listing(id: "a"), try listing(id: "b")])

        m.selectFirstRowIfNeeded()
        XCTAssertEqual(m.focused, "a")

        // 已经有焦点时不动它——刷新回来不能把用户看的那条抢走。
        m.focused = "b"
        m.selectFirstRowIfNeeded()
        XCTAssertEqual(m.focused, "b")
    }

    /// ⇧↑ / ⇧↓ 把新落点**并进**选择集，不替换。
    @MainActor
    func testShiftArrowExtendsSelection() throws {
        let m = BrowseModel()
        loaded(m, [try listing(id: "a"), try listing(id: "b"), try listing(id: "c")])

        m.moveSelection(by: 1)                      // a
        m.moveSelection(by: 1, extending: true)     // a + b
        m.moveSelection(by: 1, extending: true)     // a + b + c
        XCTAssertEqual(m.selection, ["a", "b", "c"])
        XCTAssertEqual(m.focused, "c", "焦点仍然跟到最新那条")
    }

    /// ⇧ 点选：整段选上，两端都含。
    ///
    /// 换成自绘 `List` 之后多选是自己实现的（`Table` 本来白送），所以要钉住。
    @MainActor
    func testSelectRangeCoversBothEnds() throws {
        let m = BrowseModel()
        loaded(m, [try listing(id: "a"), try listing(id: "b"),
                   try listing(id: "c"), try listing(id: "d")])

        m.selectRange(from: "b", to: "d")
        XCTAssertEqual(m.selection, ["b", "c", "d"])
        XCTAssertEqual(m.focused, "d", "焦点落在点的那条，下次 ⇧ 点以它为锚")
    }

    /// 反着拖也一样：从下往上选，区间不该是空的。
    @MainActor
    func testSelectRangeBackwards() throws {
        let m = BrowseModel()
        loaded(m, [try listing(id: "a"), try listing(id: "b"), try listing(id: "c")])
        m.selectRange(from: "c", to: "a")
        XCTAssertEqual(m.selection, ["a", "b", "c"])
    }

    /// ⇧ 点选走的是**可见行**：被搜索筛掉的那些不该被圈进区间。
    @MainActor
    func testSelectRangeSkipsFilteredOutRows() async throws {
        let m = BrowseModel()
        loaded(m, [
            try listing(id: "a", name: "Kastanjelaan 1"),
            try listing(id: "b", name: "Vestdijk 2"),
            try listing(id: "c", name: "Kastanjelaan 3"),
        ])
        m.searchText = "kastanjelaan"
        await m.updateRows(debounce: false)

        m.selectRange(from: "a", to: "c")
        XCTAssertEqual(m.selection, ["a", "c"], "中间的 b 被筛掉了，不该进选择集")
    }

    /// 搜索把当前选中那条筛掉之后，焦点落到第一条可见行，而不是留一个看不见的选中项。
    @MainActor
    func testSearchThatHidesFocusedRowMovesFocus() async throws {
        let m = BrowseModel()
        loaded(m, [
            try listing(id: "a", name: "Kastanjelaan 1"),
            try listing(id: "b", name: "Vestdijk 2"),
        ])
        m.focused = "b"
        m.selection = ["b"]

        m.searchText = "kastanjelaan"
        await m.updateRows(debounce: false)
        m.reconcileSelection()

        XCTAssertEqual(m.focused, "a")
        XCTAssertEqual(m.selection, ["a"])
    }
}
