import XCTest
@testable import FlatRadar
@testable import FlatRadarCore

/// ``CalendarDateMath`` 的日期范围计算。
@MainActor
final class CalendarDateMathTests: XCTestCase {

    /// 日期范围测试和月历都使用 `ServerTime.calendar`，不依赖运行机器的时区。
    private let cal = ServerTime.calendar

    // MARK: - 日历必须和服务端同一个时区

    /// 月历必须使用服务端时区，而不是设备当前时区。
    ///
    func testCalendarUsesServerTimeZone() {
        XCTAssertEqual(ServerTime.calendar.timeZone, ServerTime.timeZone)
        XCTAssertNotEqual(ServerTime.calendar.timeZone, TimeZone(identifier: "UTC"),
                          "服务端时区不是 UTC——真是 UTC 的话这条测试就失去意义了")
    }

    /// 同一个月初在 UTC 设备日历中可能落在上个月。
    func testMonthOfAServerMonthStartIsStableAcrossDeviceTimeZones() {
        let server = ServerTime.calendar
        let sept = server.date(from: DateComponents(year: 2026, month: 9, day: 1))!

        XCTAssertEqual(server.dateComponents([.month], from: sept).month, 9)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(utc.dateComponents([.month], from: sept).month, 8,
                       "这条**故意**断言 8——它就是 bug 的样子。"
                       + "两边日历不一致时，UTC 设备会把服务端的 9 月月初读成 8 月。")
    }

    // MARK: - monthSpan

    /// 边界月要整月可用：数据从月中某天起，那个月的 1 号也得在范围里，
    /// 否则前半个月全是灰的，翻不进去也点不了。
    ///
    /// 日期全部**相对今天**取。写死 2026 年那几天的话，这个测试过几个月就会自己
    /// 失效——`monthSpan` 会把今天所在的月并进来，"下个月不该被带进来"那条
    /// 断言到时候就不成立了。
    func testMonthSpanCoversWholeBoundaryMonths() {
        // 数据从下个月中旬开始，到第三个月为止；今天所在的月会被并进来当下界。
        let span = CalendarDateMath.monthSpan(
            (start: monthStart(offset: 1).addingTimeInterval(86_400 * 19),
             end: monthStart(offset: 3).addingTimeInterval(86_400 * 2)))

        XCTAssertTrue(span.contains(monthStart(offset: 0)), "首月月初必须在范围内")
        XCTAssertTrue(span.contains(monthStart(offset: 4).addingTimeInterval(-1)),
                      "末月月末必须在范围内")
        XCTAssertFalse(span.contains(monthStart(offset: 0).addingTimeInterval(-1)),
                       "上一个月不该被带进来")
        XCTAssertFalse(span.contains(monthStart(offset: 4)), "再往后一个月不该被带进来")
    }

    /// 今天所在月的月初往后数 `offset` 个月。
    private func monthStart(offset: Int) -> Date {
        let thisMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        return cal.date(byAdding: .month, value: offset, to: thisMonth)!
    }

    /// 当前月始终留在日期范围内，方便 Today 和初始月份使用。
    func testMonthSpanAlwaysIncludesToday() {
        let today = Date()
        let farFuture = cal.date(byAdding: .month, value: 6, to: today)!
        let span = CalendarDateMath.monthSpan(
            (start: cal.date(byAdding: .month, value: 3, to: today)!, end: farFuture))
        XCTAssertTrue(span.contains(today))

        let farPast = cal.date(byAdding: .month, value: -6, to: today)!
        let past = CalendarDateMath.monthSpan(
            (start: farPast, end: cal.date(byAdding: .month, value: -3, to: today)!))
        XCTAssertTrue(past.contains(today))
    }

    /// 每个月的第一天都包含在扩展后的范围内。
    func testMonthStartIsInsideTheSpan() {
        let span = CalendarDateMath.monthSpan(
            (start: date(2026, 8, 20), end: date(2026, 11, 3)))
        for offset in 0...3 {
            let month = ServerTime.calendar.date(byAdding: .month, value: offset,
                                                 to: span.start)!
            let monthStart = CalendarDateMath.startOfMonth(month)
            XCTAssertTrue(span.contains(monthStart),
                          "第 \(offset) 个月的月初 \(monthStart) 不在 \(span) 里")
        }
    }

    /// 首尾传反了也不能算出一个空区间。
    func testMonthSpanToleratesReversedRange() {
        let span = CalendarDateMath.monthSpan(
            (start: date(2026, 11, 3), end: date(2026, 9, 20)))
        XCTAssertTrue(span.contains(date(2026, 9, 1)))
        XCTAssertTrue(span.contains(date(2026, 11, 30)))
    }

    /// 同一天的首尾也要撑出整整一个月。
    func testMonthSpanWithSingleDay() {
        let day = date(2026, 9, 20)
        let span = CalendarDateMath.monthSpan((start: day, end: day))
        XCTAssertTrue(span.contains(date(2026, 9, 1)))
        XCTAssertTrue(span.contains(date(2026, 9, 30)))
    }

    func testMonthPageIDsCrossYearAndDaylightSavingBoundaries() {
        let start = date(2025, 10, 29)
        let end = date(2026, 4, 2)
        let pages = CalendarDateMath.months(in: (start, end), fallback: start)
        let expected = (0..<7).map {
            cal.date(byAdding: .month, value: $0,
                     to: CalendarDateMath.startOfMonth(start))!
        }
        XCTAssertTrue(expected.allSatisfy(pages.contains))
        XCTAssertEqual(Set(pages).count, pages.count)
        for (previous, next) in zip(pages, pages.dropFirst()) {
            XCTAssertEqual(cal.date(byAdding: .month, value: 1, to: previous), next)
            XCTAssertEqual(cal.component(.day, from: next), 1)
            XCTAssertEqual(cal.component(.hour, from: next), 0)
        }
    }

    func testExpandingRangePreservesExistingPageIDs() {
        let first = monthStart(offset: -1)
        let last = monthStart(offset: 2)
        let initial = CalendarDateMath.months(in: (first, last), fallback: Date())
        let expanded = CalendarDateMath.months(
            in: (monthStart(offset: -3), monthStart(offset: 4)), fallback: Date())
        XCTAssertEqual(expanded.filter { initial.contains($0) }, initial)
        XCTAssertTrue(initial.contains(monthStart(offset: 0)))
    }

    func testEmptyRangeProducesOnlyNormalizedFallbackPage() {
        let fallback = date(2026, 2, 17)
        XCTAssertEqual(CalendarDateMath.months(in: nil, fallback: fallback),
                       [CalendarDateMath.startOfMonth(fallback)])
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
}
