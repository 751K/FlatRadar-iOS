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

    // MARK: - 日历必须和服务端同一个时区

    /// **这是 build 295→307 那个"日历停在 8 月"的根源，钉死它。**
    ///
    /// `CalendarView` 用「格里高利 + Europe/Amsterdam」算 anchor，而
    /// `NativeMonthCalendar` 曾经用 `Calendar.current`。同一个时刻在两个时区里
    /// 会落在**不同的月**：
    ///
    ///     9 月 1 日 00:00 阿姆斯特丹 == 8 月 31 日 22:00 UTC
    ///     用 Amsterdam 读 → 9 月；用 UTC / 洛杉矶读 → 8 月
    ///
    /// 真机在阿姆时区看不到，只有 CI 的模拟器复现——所以我按"UICalendarView 的
    /// 吸附时机"猜了五轮，全是错的。两份日历只要还分开，这类"只在某些时区出现"
    /// 的错就会继续冒。
    func testCalendarUsesServerTimeZone() {
        XCTAssertEqual(ServerTime.calendar.timeZone, ServerTime.timeZone)
        XCTAssertNotEqual(ServerTime.calendar.timeZone, TimeZone(identifier: "UTC"),
                          "服务端时区不是 UTC——真是 UTC 的话这条测试就失去意义了")
    }

    /// 上面那个时区差在**月初**会翻月，这里把它复现出来当回归。
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
    /// availableDateRange"。只给 year + month 不是日期。
    func testVisibleComponentsCarryADay() {
        let comps = NativeMonthCalendar.visibleComponents(for: date(2026, 9, 20))
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 9)
        XCTAssertEqual(comps.day, 1, "取的是月初")
        XCTAssertNotNil(ServerTime.calendar.date(from: comps), "组件必须能解析回 Date")
    }

    /// 月初一定落在 `monthSpan` 给出的范围里——这是不用再做 clamp 的依据。
    ///
    /// 之前那版为了「保证 within availableDateRange」加了一段把月初抬到范围起点
    /// 的兜底，结果自相矛盾：抬完再截断到 day 粒度又变回 0 点。这条测试直接钉住
    /// 真正成立的那个不变式。
    func testMonthStartIsInsideTheSpan() {
        let span = NativeMonthCalendar.monthSpan(
            (start: date(2026, 8, 20), end: date(2026, 11, 3)))
        for offset in 0...3 {
            let month = ServerTime.calendar.date(byAdding: .month, value: offset,
                                                 to: span.start)!
            let comps = NativeMonthCalendar.visibleComponents(for: month)
            let resolved = ServerTime.calendar.date(from: comps)!
            XCTAssertTrue(span.contains(resolved),
                          "第 \(offset) 个月的月初 \(resolved) 不在 \(span) 里")
        }
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
