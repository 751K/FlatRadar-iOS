import XCTest
import FlatRadarCore
@testable import FlatRadarMac

/// 四屏的派生数据缓存（代码审查：地图缩放、日历、列表、通知的重复计算）。
///
/// 钉三件事：
/// 1. **读很多遍只算一次**——这是性能问题本身；
/// 2. **输入一变就重算**——缓存最怕的是显示旧结果，比慢更糟；
/// 3. 顺手改快的那两处（日历每日排序）**结果和原来一模一样**。
///
/// 最后一组是 2000 条下的计时，只打印、不按毫秒断言（机器负载一变就会误报），
/// 断言的是"命中缓存的读取比重算快一个数量级以上"。
@MainActor
final class DerivedDataCacheTests: XCTestCase {

    // MARK: - Memo 本身

    func test_同一个键只算一次_换键才重算() {
        let memo = Memo<Int, String>()
        var calls = 0
        for _ in 0..<5 { _ = memo.value(for: 1) { calls += 1; return "a" } }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(memo.value(for: 2) { calls += 1; return "b" }, "b")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(memo.computeCount, 2)
    }

    func test_数组当键_改了其中一条就重算() {
        let memo = Memo<[Int], Int>()
        var data = Array(0..<1000)
        _ = memo.value(for: data) { data.reduce(0, +) }
        data[500] = -1                                  // 原地改一条，数量不变
        XCTAssertEqual(memo.value(for: data) { data.reduce(0, +) }, data.reduce(0, +))
        XCTAssertEqual(memo.computeCount, 2, "内容变了必须重算，否则界面停在旧数据上")
    }

    // MARK: - 地图缩放档位

    func test_同一档里缩放_档位相等_不触发重画() {
        // 缩放时 `.continuous` 回调每帧一个跨度。同一档里它们必须相等，
        // MapPane 才会跳过写界面状态。
        XCTAssertEqual(MapZoomBand(span: 0.10), MapZoomBand(span: 0.30))
        XCTAssertEqual(MapZoomBand(span: 0.8), MapZoomBand(span: 3))
        XCTAssertEqual(MapZoomBand(span: 0.01), MapZoomBand(span: 0.04))
    }

    func test_跨过城市团和_POI_的阈值_档位才变() {
        XCTAssertNotEqual(MapZoomBand(span: 0.49), MapZoomBand(span: 0.51))
        XCTAssertTrue(MapZoomBand(span: 0.51).showsClusters)
        XCTAssertFalse(MapZoomBand(span: 0.49).showsClusters)

        XCTAssertNotEqual(MapZoomBand(span: 0.049), MapZoomBand(span: 0.051))
        XCTAssertTrue(MapZoomBand(span: 0.049).showsPOI)
        XCTAssertFalse(MapZoomBand(span: 0.051).showsPOI)
    }

    // MARK: - 列表 rows

    func test_rows_读很多遍只过滤一次() async {
        let m = BrowseModel()
        m.listings.listings = Fixture.listings(200)
        m.query.cities = ["Amsterdam"]
        await m.updateRows(debounce: false)
        let first = m.rows
        for _ in 0..<20 { _ = m.rows }
        XCTAssertEqual(m.rowsComputeCount, 1)
        XCTAssertEqual(m.rows.map(\.id), first.map(\.id))
    }

    func test_rows_搜索词_筛选_房源任一变了就重算_结果正确() async {
        let m = BrowseModel()
        m.listings.listings = Fixture.listings(200)
        let all = m.rows.count
        XCTAssertEqual(all, 200)

        m.searchText = "Amsterdam"
        await m.updateRows(debounce: false)
        XCTAssertEqual(m.rows.count, m.listings.listings.filter { $0.city == "Amsterdam" }.count)

        m.searchText = ""
        m.query.cities = ["Utrecht"]
        await m.updateRows(debounce: false)
        XCTAssertTrue(m.rows.allSatisfy { $0.city == "Utrecht" })

        m.query = ListingQuery()
        m.listings.listings.removeFirst(10)
        XCTAssertEqual(m.rows.count, 190, "房源变了，rows 必须跟着变")
        XCTAssertEqual(m.rowsComputeCount, 2, "没有筛选时直接返回全部数据，不调后台过滤")
    }

    func test_rows_搜索词前后空格不算变化() async {
        let m = BrowseModel()
        m.listings.listings = Fixture.listings(50)
        m.searchText = "Amsterdam"
        await m.updateRows(debounce: false)
        _ = m.rows
        m.searchText = "Amsterdam  "
        await m.updateRows(debounce: false)
        _ = m.rows
        XCTAssertEqual(m.rowsComputeCount, 1)
    }

    // MARK: - 日历

    private func calendarStore(_ items: [CalendarListing]) -> CalendarStore {
        let store = CalendarStore()
        store.listings = items
        store.listingsByDay = Dictionary(grouping: items, by: \.dayKey)
        return store
    }

    func test_日历_同一个月读很多遍只建一次网格() {
        let store = calendarStore(Fixture.calendar(300, sameDay: false))
        let d = CalendarDerived()
        let anchor = CalendarGrid.startOfMonth(store.listings[0].date!)
        let today = CalendarGrid.startOfDay(Date())
        for _ in 0..<10 {
            _ = d.month(anchor: anchor, store: store, today: today)
            _ = d.excluded(store: store, thisMonth: CalendarGrid.startOfMonth(Date()))
            _ = d.nextMoveIn(store: store, today: today)
        }
        XCTAssertEqual(d.computeCounts.month, 1)
        XCTAssertEqual(d.computeCounts.excluded, 1)
        XCTAssertEqual(d.computeCounts.nextMoveIn, 1)
    }

    func test_日历_翻月_换数据_过零点_都会重建() {
        let items = Fixture.calendar(300, sameDay: false)
        let store = calendarStore(items)
        let d = CalendarDerived()
        let anchor = CalendarGrid.startOfMonth(items[0].date!)
        let today = CalendarGrid.startOfDay(Date())
        let before = d.month(anchor: anchor, store: store, today: today)

        let next = CalendarGrid.gridCalendar.date(byAdding: .month, value: 1, to: anchor)!
        XCTAssertEqual(d.month(anchor: next, store: store, today: today).grid.anchor, next)

        // 刷新回来少了一半：这个月的条数必须跟着变。
        let fewer = calendarStore(Array(items.prefix(150)))
        XCTAssertLessThan(d.month(anchor: anchor, store: fewer, today: today).grid.itemCount,
                          before.grid.itemCount)

        let tomorrow = CalendarGrid.gridCalendar.date(byAdding: .day, value: 1, to: today)!
        _ = d.month(anchor: anchor, store: fewer, today: tomorrow)
        XCTAssertEqual(d.computeCounts.month, 4)
    }

    // MARK: - 通知

    func test_通知_五个计数加统计带_只解析一次() {
        let items = Fixture.notifications(300)
        let d = AlertsDerived()
        let now = Date()
        for kind: NotificationItem.Kind? in [nil, .book, .status, .lottery, .system] {
            _ = d.parsed(items).counts[kind ?? .book]
            _ = d.presented(items, kind: nil, unreadOnly: false, now: now)
        }
        XCTAssertEqual(d.computeCounts.parsed, 1)
        XCTAssertEqual(d.computeCounts.presented, 1)
    }

    func test_通知_切筛选_标已读_都会反映出来() {
        var items = Fixture.notifications(30)
        let d = AlertsDerived()
        let now = Date()
        // 同一批数据上来回拨「Unread only」：两次结果必须不同。
        XCTAssertEqual(d.presented(items, kind: nil, unreadOnly: false, now: now).rows.count, items.count)
        let unread = d.presented(items, kind: nil, unreadOnly: true, now: now).rows.count
        XCTAssertEqual(unread, items.filter { !$0.isRead }.count)
        XCTAssertLessThan(unread, items.count, "数据里得有已读的，这一步才测得到东西")

        // 把一条未读换成已读（id 相同，只有 read 变了）：Unread only 必须少一条。
        let i = items.firstIndex { !$0.isRead }!
        items[i] = Fixture.notification(items[i].id, read: true)
        XCTAssertEqual(d.presented(items, kind: nil, unreadOnly: true, now: now).rows.count, unread - 1,
                       "已读状态变了，缓存没认出来——界面会一直把它当未读")

        XCTAssertTrue(d.presented(items, kind: .system, unreadOnly: false, now: now).rows.isEmpty)
    }

    // MARK: - 日历每日排序：改快了，顺序不能变

    func test_日历排序和原来的比较器结果完全一致() {
        let items = Fixture.calendar(600, sameDay: true)
        let reference = items.sorted { a, b in       // 改之前的写法，原样抄过来当基准
            let pa = ListingStatus.from(a.status).priority
            let pb = ListingStatus.from(b.status).priority
            if pa != pb { return pa < pb }
            let va = PriceText.parse(a.priceRaw) ?? .greatestFiniteMagnitude
            let vb = PriceText.parse(b.priceRaw) ?? .greatestFiniteMagnitude
            if va != vb { return va < vb }
            return a.id < b.id
        }
        XCTAssertEqual(CalendarGrid.sorted(items).map(\.id), reference.map(\.id))
    }

    // MARK: - 2000 条下的计时

    /// 重算一次 vs 命中缓存读一次。打印出来写进报告；断言只要求缓存快一个数量级。
    func test_两千条下_命中缓存比重算快一个数量级以上() async {
        func time(_ n: Int = 1, _ body: () -> Void) -> Double {
            let t = Date()
            for _ in 0..<n { body() }
            return Date().timeIntervalSince(t) * 1000 / Double(n)
        }
        var lines: [String] = []

        // 地图：分组 + 城市聚合
        let store = MapStore()
        store.listings = Fixture.mapListings(2000)
        let mapMemo = Memo<MapStore.VisibilityKey, [MapBuilding]>()
        let mapCold = time { _ = MapCluster.group(MapBuilding.group(store.visibleListings)) }
        _ = mapMemo.value(for: store.visibilityKey) { MapBuilding.group(store.visibleListings) }
        let mapHot = time(200) { _ = mapMemo.value(for: store.visibilityKey) { [] } }
        lines.append(String(format: "地图 分组+聚合 %.2fms → 缓存命中 %.4fms", mapCold, mapHot))

        // 列表：类型 + 能效 + 面积组合筛选 + 搜索
        let m = BrowseModel()
        m.listings.listings = Fixture.listings(2000)
        m.query.minArea = 30
        m.searchText = "straat"
        let started = Date()
        await m.updateRows(debounce: false)
        let rowsCold = Date().timeIntervalSince(started) * 1000
        let rowsHot = time(200) { _ = m.rows }
        lines.append(String(format: "列表 rows %.2fms → 缓存命中 %.4fms", rowsCold, rowsHot))

        // 日历：2000 条挤在一个月
        let cal = Fixture.calendar(2000, sameDay: false)
        let byDay = Dictionary(grouping: cal, by: \.dayKey)
        let anchor = CalendarGrid.startOfMonth(cal[0].date!)
        let gridCold = time { _ = CalendarGrid.month(containing: anchor, listingsByDay: byDay) }
        let excludedCold = time { _ = CalendarGrid.excludedCount(cal) }
        lines.append(String(format: "日历 月网格 %.2fms、排除统计 %.2fms（各只在数据 / 月份变时算一次）",
                            gridCold, excludedCold))

        // 通知：解析 2000 条
        let items = Fixture.notifications(2000)
        let alertMemo = Memo<[NotificationItem], [AlertRow]>()
        let alertCold = time { _ = items.map { AlertFeed.row($0, platforms: Platform.knownKeys) } }
        _ = alertMemo.value(for: items) { items.map { AlertFeed.row($0, platforms: Platform.knownKeys) } }
        let alertHot = time(200) { _ = alertMemo.value(for: items) { [] } }
        lines.append(String(format: "通知 解析 %.2fms（原先五个计数各一次 ≈ ×5）→ 缓存命中 %.4fms",
                            alertCold, alertHot))

        print("PERF\n" + lines.joined(separator: "\n"))
        XCTAssertLessThan(mapHot * 10, mapCold)
        XCTAssertLessThan(rowsHot * 10, rowsCold)
        XCTAssertLessThan(alertHot * 10, alertCold)
    }
}

// MARK: - 造数据

@MainActor
private enum Fixture {

    static let cities = ["Amsterdam", "Rotterdam", "Utrecht", "Eindhoven", "Den Haag"]
    static let statuses = ["Available to book", "Available in lottery", "Reserved", "Occupied"]

    static func listings(_ n: Int) -> [Listing] {
        (0..<n).map { i in
            let dict: [String: Any] = [
                "id": "L\(i)", "name": "Somestraat \(i)", "status": statuses[i % 4],
                "source": "holland2stay", "price_raw": "€\(700 + i % 900)",
                "price_value": Double(700 + i % 900),
                "available_from": "2026-10-01", "city": cities[i % cities.count],
                "url": "https://example.invalid/\(i)", "features": [],
                "feature_map": ["area": "\(20 + i % 60) m²", "type": i % 2 == 0 ? "Studio" : "Apartment",
                                "energy_label": ["A", "B", "C"][i % 3]],
            ]
            return try! JSONDecoder().decode(Listing.self, from: JSONSerialization.data(withJSONObject: dict))
        }
    }

    static func mapListings(_ n: Int) -> [MapListing] {
        (0..<n).map { i in
            // 大约 4 套一栋楼：同一栋的坐标相同。
            let b = i / 4
            let dict: [String: Any] = [
                "id": "M\(i)", "name": "Somestraat \(i)", "status": statuses[i % 4],
                "source": "holland2stay", "price_raw": "€\(700 + i % 900)",
                "city": cities[b % cities.count], "neighborhood": "", "building": "B\(b)",
                "area": "50 m²", "address": "Somestraat \(i)", "available_from": "2026-10-01",
                "url": "https://example.invalid/\(i)",
                "lat": 51.4 + Double(b % 97) * 0.003, "lng": 5.4 + Double(b / 97) * 0.003,
            ]
            return try! JSONDecoder().decode(MapListing.self, from: JSONSerialization.data(withJSONObject: dict))
        }
    }

    static func calendar(_ n: Int, sameDay: Bool) -> [CalendarListing] {
        (0..<n).map { i in
            let day = sameDay ? 15 : 1 + i % 28
            // 价格里故意混进读不出来的，排序要把它们沉底。
            let price = i % 7 == 0 ? "on request" : "€\(700 + (i * 37) % 900)"
            let json = """
            {"id":"C\(i)","name":"Unit \(i)","status":"\(statuses[i % 4])",
             "available_from":"2026-10-\(String(format: "%02d", day))","price_raw":"\(price)",
             "building":"B\(i % 40)"}
            """
            return try! JSONDecoder().decode(CalendarListing.self, from: Data(json.utf8))
        }
    }

    static func notifications(_ n: Int) -> [NotificationItem] {
        (0..<n).map { notification($0, read: $0 % 3 == 0) }
    }

    static func notification(_ i: Int, read: Bool) -> NotificationItem {
        let json = """
        {"id":\(i),"created_at":"2026-09-\(String(format: "%02d", 1 + i % 17))T09:38:00",
         "type":"status_change","title":"[H2S] Somestraat \(i)",
         "body":"Reserved → Available to book · €1.\(200 + i % 700)/mo",
         "read":\(read ? 1 : 0),"listing_id":"L\(i)","url":"https://x"}
        """
        return try! JSONDecoder().decode(NotificationItem.self, from: Data(json.utf8))
    }
}
