import XCTest
@testable import FlatRadar

/// ``NativeMonthCalendar`` 里两个纯函数。
///
/// 守的是「点一下翻不过去，点两下才行」
/// ------------------------------------
/// `UICalendarSelectionSingleDate.setSelected(_:animated:)` 不只是改选中态，它
/// 还会**把日历滚到那一天所在的月份**（头文件："Sets the selected date to be
/// displayed in the calendar"）。所以 `updateUIView` 里那句判等一旦失准，多调
/// 的那一次就会把用户刚翻到的月份拽回去。
///
/// 而 `DateComponents ==` 恰好就是不准的：它把 `calendar` / `timeZone` /
/// `era` / `isLeapMonth` 一并比进去。用户点日期后 UIKit 写回 `selectedDate` 的
/// 那份组件带 calendar 和 timeZone，我们现造的那份不带——同一天，`!=` 永远为真。
///
/// 现象是：点「下一月」看着没反应（被拽回来了），再点一次才成——第二次
/// `visibleMonth` 已经是目标月，delegate 不再回写，也就不再触发那次更新。
///
/// 这批测试钉住 ``NativeMonthCalendar/isSameDay(_:_:)``：**带多余字段的两份
/// 组件，只要年月日相同就必须相等**。
@MainActor
final class NativeMonthCalendarTests: XCTestCase {

    private let cal = Calendar.current

    // MARK: - isSameDay

    /// 核心那条：UIKit 那份带 calendar / timeZone，我们那份不带。
    func testIsSameDayIgnoresCalendarAndTimeZone() {
        var fromUIKit = DateComponents()
        fromUIKit.year = 2026
        fromUIKit.month = 9
        fromUIKit.day = 5
        fromUIKit.calendar = Calendar(identifier: .gregorian)
        fromUIKit.timeZone = TimeZone(identifier: "Europe/Amsterdam")
        fromUIKit.era = 1
        fromUIKit.isLeapMonth = false

        let ours = DateComponents(year: 2026, month: 9, day: 5)

        // 先确认这两份**用 == 比是不相等的**——否则这个测试就没在守东西了。
        XCTAssertNotEqual(fromUIKit, ours,
                          "如果 DateComponents == 变得能忽略这些字段，isSameDay 就可以删了")
        XCTAssertTrue(NativeMonthCalendar.isSameDay(fromUIKit, ours))
    }

    func testIsSameDayDistinguishesDifferentDays() {
        let a = DateComponents(year: 2026, month: 9, day: 5)
        XCTAssertFalse(NativeMonthCalendar.isSameDay(a, DateComponents(year: 2026, month: 9, day: 6)))
        XCTAssertFalse(NativeMonthCalendar.isSameDay(a, DateComponents(year: 2026, month: 10, day: 5)))
        XCTAssertFalse(NativeMonthCalendar.isSameDay(a, DateComponents(year: 2025, month: 9, day: 5)))
    }

    /// nil 是「没有选中」，要能和「有选中」区分开——清空选中态靠的就是这条。
    func testIsSameDayHandlesNil() {
        let a = DateComponents(year: 2026, month: 9, day: 5)
        XCTAssertTrue(NativeMonthCalendar.isSameDay(nil, nil))
        XCTAssertFalse(NativeMonthCalendar.isSameDay(a, nil))
        XCTAssertFalse(NativeMonthCalendar.isSameDay(nil, a))
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
        let span = NativeMonthCalendar.monthSpan(
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

    /// 今天所在的月必须在范围里。初始 `visibleMonth` 和工具栏 Today 都指向它，
    /// 而头文件要求 `visibleDateComponents` 落在 `availableDateRange` 之内。
    func testMonthSpanAlwaysIncludesToday() {
        let today = Date()
        let farFuture = cal.date(byAdding: .month, value: 6, to: today)!
        let span = NativeMonthCalendar.monthSpan(
            (start: cal.date(byAdding: .month, value: 3, to: today)!, end: farFuture))
        XCTAssertTrue(span.contains(today))

        let farPast = cal.date(byAdding: .month, value: -6, to: today)!
        let past = NativeMonthCalendar.monthSpan(
            (start: farPast, end: cal.date(byAdding: .month, value: -3, to: today)!))
        XCTAssertTrue(past.contains(today))
    }

    /// `visibleComponents` 必须给出**能解析成日期的**组件（含 day）。
    ///
    /// 头文件对 `visibleDateComponents` 说的是 "must also be a valid date within
    /// availableDateRange"。只给 year + month 不是日期，赋值会被忽略——
    /// build 295 / 302 / 304 的日历始终停在 8 月就是这么来的。
    func testVisibleComponentsCarryADay() {
        let comps = NativeMonthCalendar.visibleComponents(for: date(2026, 9, 20), in: nil)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 9)
        XCTAssertNotNil(comps.day, "没有 day 就不是一个日期，UICalendarView 会忽略")
        XCTAssertNotNil(cal.date(from: comps), "组件必须能解析回 Date")
    }

    /// 边界月：月初早于可用范围起点时，要取范围起点——否则违反同一句话的后半段
    /// 「within availableDateRange」，一样会被忽略。
    func testVisibleComponentsStayInsideTheRange() {
        let rangeStart = date(2026, 9, 20)
        let span = DateInterval(start: rangeStart, end: date(2026, 11, 30))
        let comps = NativeMonthCalendar.visibleComponents(for: date(2026, 9, 1), in: span)
        let resolved = try? XCTUnwrap(cal.date(from: comps))
        XCTAssertEqual(comps.day, 20, "该被抬到范围起点那天")
        if let resolved { XCTAssertTrue(span.contains(resolved)) }
    }

    /// 首尾传反了也不能算出一个空区间。
    func testMonthSpanToleratesReversedRange() {
        let span = NativeMonthCalendar.monthSpan(
            (start: date(2026, 11, 3), end: date(2026, 9, 20)))
        XCTAssertTrue(span.contains(date(2026, 9, 1)))
        XCTAssertTrue(span.contains(date(2026, 11, 30)))
    }

    /// 同一天的首尾也要撑出整整一个月。
    func testMonthSpanWithSingleDay() {
        let day = date(2026, 9, 20)
        let span = NativeMonthCalendar.monthSpan((start: day, end: day))
        XCTAssertTrue(span.contains(date(2026, 9, 1)))
        XCTAssertTrue(span.contains(date(2026, 9, 30)))
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
}
