import XCTest
@testable import FlatRadarMac
@testable import FlatRadarCore

/// 日历网格的日期算术。
///
/// 为什么这一组值得写
/// ----------------
/// 日期是这个工程翻过最贵的车：`CalendarView` 用服务端时区、
/// `NativeMonthCalendar` 用 `Calendar.current`，两者在**月初那一刻**差整整一个
/// 月，日历从 build 295 到 307 一直停在 8 月，而且只在 CI 的 UTC 模拟器上复现
/// （见 ``ServerTime/calendar`` 的注释）。这里每一条都钉死走
/// ``CalendarGrid/gridCalendar``，不给 `Calendar.current` 留缝。
final class CalendarGridTests: XCTestCase {

    // 每个用例都标 `@MainActor`：Mac target 默认 MainActor 隔离，``CalendarGrid``
    // 随之也是主 actor 的，而 `XCTestCase` 的方法默认 nonisolated。
    // 和 ``BrowseModelTests`` 同一个写法。

    /// 用服务端时区构造一个确定的日子，避免测试自己引进本地时区。
    @MainActor
    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = ServerTime.calendar
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    @MainActor
    private func listing(_ id: String, _ availableFrom: String,
                         status: String = "Occupied",
                         price: String = "€1000",
                         building: String = "") -> CalendarListing {
        let json = """
        {"id":"\(id)","name":"Unit \(id)","status":"\(status)",
         "available_from":"\(availableFrom)","price_raw":"\(price)","building":"\(building)"}
        """
        return try! JSONDecoder().decode(CalendarListing.self, from: Data(json.utf8))
    }

    @MainActor
    private func grouped(_ items: [CalendarListing]) -> [String: [CalendarListing]] {
        Dictionary(grouping: items, by: \.dayKey)
    }

    // MARK: - 网格骨架

    @MainActor
    func test_网格从周一起排() {
        let grid = CalendarGrid.month(containing: date("2026-09-15"), listingsByDay: [:])
        let first = grid.weeks[0].days[0]
        // 2026-09-01 是周二，所以网格第一天该是 8-31（周一）。
        XCTAssertEqual(CalendarGrid.dayKey(first.date), "2026-08-31")
        XCTAssertFalse(first.isInMonth)
        XCTAssertEqual(CalendarGrid.weekdaySymbols.first, "Mon")
        XCTAssertEqual(CalendarGrid.weekdaySymbols.last, "Sun")
    }

    @MainActor
    func test_每周都是整七天() {
        for iso in ["2026-02-10", "2026-09-15", "2027-01-01", "2028-02-29"] {
            let grid = CalendarGrid.month(containing: date(iso), listingsByDay: [:])
            for week in grid.weeks {
                XCTAssertEqual(week.days.count, 7, "\(iso) 有一周不是 7 天")
            }
        }
    }

    /// 2026-02 的 1 号正好是周日：`leadingOffset` 要补满 6 天，
    /// 而 28 天 + 6 = 34，得排 5 行。少算一行会把月底切掉。
    @MainActor
    func test_月初是周日时前面补六天() {
        let feb = date("2026-02-01")
        XCTAssertEqual(CalendarGrid.leadingOffset(of: feb), 6)
        let grid = CalendarGrid.month(containing: feb, listingsByDay: [:])
        XCTAssertEqual(grid.weeks.count, 5)
        let inMonth = grid.weeks.flatMap(\.days).filter(\.isInMonth)
        XCTAssertEqual(inMonth.count, 28)
        XCTAssertEqual(inMonth.last.map { CalendarGrid.dayKey($0.date) }, "2026-02-28")
    }

    /// 需要 6 行的月份必须真给 6 行——只给 5 行的话最后几天整个消失。
    @MainActor
    func test_需要六行的月份不会被切掉() {
        let grid = CalendarGrid.month(containing: date("2026-08-15"), listingsByDay: [:])
        XCTAssertEqual(grid.weeks.count, 6)
        let inMonth = grid.weeks.flatMap(\.days).filter(\.isInMonth)
        XCTAssertEqual(inMonth.count, 31)
    }

    @MainActor
    func test_闰年二月有二十九天() {
        let grid = CalendarGrid.month(containing: date("2028-02-10"), listingsByDay: [:])
        let inMonth = grid.weeks.flatMap(\.days).filter(\.isInMonth)
        XCTAssertEqual(inMonth.count, 29)
    }

    // MARK: - 落格

    @MainActor
    func test_房源落到正确的格子并只算本月的() {
        // 8-31 出现在 9 月网格的第一格里，但它**不属于** 9 月，
        // 不能计进 itemCount——否则统计带的数字会比状态栏的多。
        let items = [listing("a", "2026-08-31"),
                     listing("b", "2026-09-01"),
                     listing("c", "2026-09-01"),
                     listing("d", "2026-09-30")]
        let grid = CalendarGrid.month(containing: date("2026-09-10"),
                                      listingsByDay: grouped(items))
        XCTAssertEqual(grid.itemCount, 3)

        let days = grid.weeks.flatMap(\.days)
        XCTAssertEqual(days.first { CalendarGrid.dayKey($0.date) == "2026-08-31" }?.count, 1)
        XCTAssertEqual(days.first { CalendarGrid.dayKey($0.date) == "2026-09-01" }?.count, 2)
    }

    @MainActor
    func test_楼盘数不把空名字算成一栋() {
        let items = [listing("a", "2026-09-01", building: "WFC Lofts"),
                     listing("b", "2026-09-02", building: "WFC Lofts"),
                     listing("c", "2026-09-03", building: ""),
                     listing("d", "2026-09-04", building: "")]
        let grid = CalendarGrid.month(containing: date("2026-09-10"),
                                      listingsByDay: grouped(items))
        XCTAssertEqual(grid.itemCount, 4)
        // 两条没名字的**不算**一栋楼，否则会并成一个假的"1 栋"。
        XCTAssertEqual(grid.buildingCount, 1)
    }

    // MARK: - 同一天里的排序

    /// 格子里只放得下 3 条，被挤掉的必须是最不值得看的那些。
    @MainActor
    func test_同一天可订的排在已占之前() {
        let items = [listing("occ", "2026-09-07", status: "Occupied", price: "€500"),
                     listing("lot", "2026-09-07", status: "Available in lottery", price: "€900"),
                     listing("bok", "2026-09-07", status: "Available to book", price: "€1200")]
        let sorted = CalendarGrid.sorted(items)
        XCTAssertEqual(sorted.map(\.id), ["bok", "lot", "occ"])
    }

    @MainActor
    func test_同状态按价格便宜的在前_解析不出价格的沉底() {
        let items = [listing("c", "2026-09-07", price: "n.v.t."),
                     listing("b", "2026-09-07", price: "€ 1.200,00"),
                     listing("a", "2026-09-07", price: "€900")]
        XCTAssertEqual(CalendarGrid.sorted(items).map(\.id), ["a", "b", "c"])
    }

    // MARK: - 窗口与离群日期

    /// 实测生产数据跨度 2017-08 → 2027-10（3714 天），里面有几条哨兵日期。
    /// 窗口把它们挡在外面，而且**数得出来**——界面要明说排除了几条。
    @MainActor
    func test_窗口外的条目被数出来而不是闷掉() {
        let now = date("2026-09-10")
        let items = [listing("old", "2017-08-01"),      // 远古
                     listing("far", "3000-01-08"),      // 哨兵
                     listing("ok1", "2026-09-01"),
                     listing("ok2", "2027-08-15"),      // +11 个月，在窗口内
                     listing("edge", "2025-10-01")]     // −11 个月，在窗口内
        XCTAssertEqual(CalendarGrid.excludedCount(items, now: now), 2)
    }

    @MainActor
    func test_窗口是今天前十二个月到后二十四个月() {
        let now = date("2026-09-10")
        let w = CalendarGrid.window(now: now)
        XCTAssertEqual(CalendarGrid.dayKey(w.first), "2025-09-01")
        XCTAssertEqual(CalendarGrid.dayKey(w.last), "2028-09-01")
    }

    /// 日期解析不出来的也算在窗口外——不能悄悄当成"今天"塞进网格。
    @MainActor
    func test_日期解析不出来的算在窗口外() {
        let items = [listing("bad", "not-a-date")]
        XCTAssertEqual(CalendarGrid.excludedCount(items, now: date("2026-09-10")), 1)
    }

    // MARK: - 时区

    /// 这一条守的就是 build 295→307 那个事故：月初那一刻不能滑到上个月。
    ///
    /// 2026-09-01 00:00 Amsterdam = 2026-08-31 22:00 UTC。用 `Calendar.current`
    /// 在 UTC 机器上读它，得到的是 8 月。
    @MainActor
    func test_月初那一刻仍然属于本月() {
        let firstMoment = date("2026-09-01")
        XCTAssertEqual(CalendarGrid.dayKey(CalendarGrid.startOfMonth(firstMoment)), "2026-09-01")

        let grid = CalendarGrid.month(containing: firstMoment, listingsByDay: [:])
        XCTAssertEqual(grid.title, "September 2026")
    }

    @MainActor
    func test_网格日历用服务端时区且只改了周起点() {
        XCTAssertEqual(CalendarGrid.gridCalendar.timeZone, ServerTime.timeZone)
        XCTAssertEqual(CalendarGrid.gridCalendar.firstWeekday, 2)
    }
}
