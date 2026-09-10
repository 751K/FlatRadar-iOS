import Foundation
import FlatRadarCore

/// 日历屏的纯数据层：把 `/calendar` 那串条目铺成「月 → 周 → 天」的网格。
///
/// 单独一个文件、不碰 SwiftUI，是为了能测——日期这块最容易出只在某些时区
/// 复现的错（见 ``ServerTime/calendar`` 那段注释里 build 295→307 的事故）。
///
/// 一律走 ``ServerTime/calendar``
/// ---------------------------
/// 后端发的 `available_from` 是 Europe/Amsterdam 时区里的日子。凡是要回答
/// 「这是几月」「这是哪一天」的地方都必须用那个日历，`Calendar.current` 会在
/// **月初那一刻**差整整一个月。这里唯一的偏离是把 `firstWeekday` 改成周一
/// （见 ``gridCalendar``），时区仍然是服务端那个。

// MARK: - 一天

struct CalendarDay: Identifiable, Hashable {

    let date: Date
    /// 是不是当前这个月的日子。网格首尾会补上邻月的几天来凑满整周。
    let isInMonth: Bool
    let isToday: Bool
    let isWeekend: Bool
    let dayNumber: Int
    /// 这天起租的房源，按状态优先级排过（可订 > 抽签 > … ）。
    let items: [CalendarListing]

    var id: Date { date }
    var count: Int { items.count }
}

// MARK: - 一周

struct CalendarWeek: Identifiable, Hashable {
    /// 用这一周第一天当 id——周序号在跨月翻页时会重复。
    let id: Date
    let days: [CalendarDay]
}

// MARK: - 一个月

struct CalendarMonthGrid {

    let anchor: Date            // 该月 1 号 00:00（服务端时区）
    let weeks: [CalendarWeek]
    let itemCount: Int
    /// 这个月的条目分布在几栋楼里。设计稿统计带上那句 "across N buildings"。
    let buildingCount: Int

    var title: String { Self.titleFormatter.string(from: anchor) }

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = ServerTime.calendar
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "LLLL yyyy"
        return f
    }()
}

// MARK: - 组装

enum CalendarGrid {

    /// 画网格用的日历：时区仍是服务端的，只把一周的起点挪到**周一**。
    ///
    /// 设计稿的表头是 Mon…Sun，而 `.gregorian` 默认 `firstWeekday = 1`（周日）。
    /// 只改这一个字段、不碰时区——否则就又变回两份日历了。
    static let gridCalendar: Calendar = {
        var c = ServerTime.calendar
        c.firstWeekday = 2
        return c
    }()

    /// 可翻阅的月份窗口：**今天往前 12 个月、往后 24 个月**。
    ///
    /// 为什么要有窗口，而不是照数据的 min/max
    /// ------------------------------------
    /// 实测生产数据（691 条）的跨度是 2017-08 → 2027-10，**3714 天**，
    /// 可里面 2017-08、2021-08、2024-05 各只有 1 条——那是陈旧记录和平台的
    /// 哨兵日期，不是真的起租日。照 min/max 定范围的话，‹ › 要按 123 次才能
    /// 走完，其中 100 多个月是全空的。
    ///
    /// 取 −12/+24 之后实测只排除掉 3 条（就是上面那三个离群点），
    /// 而窗口边界是一句能说清的规则，不是拍脑袋的魔数。被排除的条数由
    /// ``excludedCount(_:now:)`` 报出来，界面明说，不闷掉。
    static let monthsBack = 12
    static let monthsForward = 24

    /// 窗口的第一个月和最后一个月（都取该月 1 号）。
    static func window(now: Date = Date()) -> (first: Date, last: Date) {
        let thisMonth = startOfMonth(now)
        let first = gridCalendar.date(byAdding: .month, value: -monthsBack, to: thisMonth) ?? thisMonth
        let last = gridCalendar.date(byAdding: .month, value: monthsForward, to: thisMonth) ?? thisMonth
        return (first, last)
    }

    /// 落在窗口外、因而根本画不出来的条目数。界面要把它说出来。
    static func excludedCount(_ listings: [CalendarListing], now: Date = Date()) -> Int {
        let w = window(now: now)
        guard let end = gridCalendar.date(byAdding: .month, value: 1, to: w.last) else { return 0 }
        return listings.filter { l in
            guard let d = l.date else { return true }   // 日期解析不出来的也算在外
            return d < w.first || d >= end
        }.count
    }

    /// 把某个月铺成 5–6 行整周。
    ///
    /// `listingsByDay` 的 key 是 `yyyy-MM-dd`，和 ``CalendarListing/dayKey`` 对齐。
    static func month(containing date: Date,
                      listingsByDay: [String: [CalendarListing]],
                      now: Date = Date()) -> CalendarMonthGrid {

        let anchor = startOfMonth(date)
        let dayCount = gridCalendar.range(of: .day, in: .month, for: anchor)?.count ?? 30

        // 网格从「包含 1 号的那一周的周一」开始，铺满整周为止。
        let leading = leadingOffset(of: anchor)
        let gridStart = gridCalendar.date(byAdding: .day, value: -leading, to: anchor) ?? anchor
        let rows = Int(ceil(Double(leading + dayCount) / 7.0))

        let today = startOfDay(now)
        var weeks: [CalendarWeek] = []
        var monthItems: [CalendarListing] = []

        for row in 0..<rows {
            guard let weekStart = gridCalendar.date(byAdding: .day, value: row * 7, to: gridStart)
            else { continue }
            var days: [CalendarDay] = []
            for offset in 0..<7 {
                guard let day = gridCalendar.date(byAdding: .day, value: offset, to: weekStart)
                else { continue }
                let inMonth = gridCalendar.isDate(day, equalTo: anchor, toGranularity: .month)
                let items = sorted(listingsByDay[dayKey(day)] ?? [])
                if inMonth { monthItems.append(contentsOf: items) }
                days.append(CalendarDay(
                    date: day,
                    isInMonth: inMonth,
                    isToday: day == today,
                    isWeekend: gridCalendar.isDateInWeekend(day),
                    dayNumber: gridCalendar.component(.day, from: day),
                    items: items))
            }
            weeks.append(CalendarWeek(id: weekStart, days: days))
        }

        // 楼盘名可能是空的（`building` 来自 feature_map，各平台填法不一），
        // 空的不算一栋楼，否则「across N buildings」会把所有没名字的并成一栋。
        let buildings = Set(monthItems.map(\.building).filter { !$0.isEmpty })

        return CalendarMonthGrid(anchor: anchor,
                                 weeks: weeks,
                                 itemCount: monthItems.count,
                                 buildingCount: buildings.count)
    }

    /// 表头 Mon…Sun。跟着 ``gridCalendar`` 的 `firstWeekday` 走，不写死。
    static var weekdaySymbols: [String] {
        let f = DateFormatter()
        f.calendar = gridCalendar
        f.locale = Locale(identifier: "en_US_POSIX")
        let symbols = f.shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let shift = gridCalendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    // MARK: - 小工具

    static func startOfMonth(_ date: Date) -> Date {
        gridCalendar.date(from: gridCalendar.dateComponents([.year, .month], from: date)) ?? date
    }

    static func startOfDay(_ date: Date) -> Date {
        gridCalendar.startOfDay(for: date)
    }

    /// 1 号前面要补几天邻月的。
    ///
    /// `weekday` 是 1…7 且**固定以周日为 1**，跟 `firstWeekday` 无关——
    /// 这一点很容易记反，所以显式换算成「离本周第一天几天」。
    static func leadingOffset(of monthStart: Date) -> Int {
        let weekday = gridCalendar.component(.weekday, from: monthStart)
        return (weekday - gridCalendar.firstWeekday + 7) % 7
    }

    static func dayKey(_ date: Date) -> String { keyFormatter.string(from: date) }

    /// 同一天里哪套排前面：可订 > 抽签 > 已订 > 其它。
    ///
    /// 和地图上 ``MapBuilding/leadStatus`` 同一个判据——格子里只放得下 3 条，
    /// 被挤掉的必须是最不值得看的那些，不能按到货顺序砍。
    static func sorted(_ items: [CalendarListing]) -> [CalendarListing] {
        items.sorted { a, b in
            let pa = ListingStatus.from(a.status).priority
            let pb = ListingStatus.from(b.status).priority
            if pa != pb { return pa < pb }
            // 同状态按价格，便宜的在前；解析不出价格的沉底。
            let va = PriceText.parse(a.priceRaw) ?? .greatestFiniteMagnitude
            let vb = PriceText.parse(b.priceRaw) ?? .greatestFiniteMagnitude
            if va != vb { return va < vb }
            return a.id < b.id
        }
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = ServerTime.calendar
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
