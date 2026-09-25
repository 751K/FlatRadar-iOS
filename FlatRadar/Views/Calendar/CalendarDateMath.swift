import Foundation
import FlatRadarCore

/// Date calculations shared by the calendar view and its regression tests.
enum CalendarDateMath {
    static let calendar = ServerTime.calendar

    /// Expand the listing range to full months and always include the current month.
    static func monthSpan(_ range: (start: Date, end: Date)) -> DateInterval {
        let today = Date()
        let lo = min(range.start, range.end, today)
        let hi = max(range.start, range.end, today)
        let start = startOfMonth(lo)
        let end = calendar.date(byAdding: DateComponents(month: 1, second: -1),
                                to: startOfMonth(hi)) ?? hi
        return DateInterval(start: start, end: max(end, start))
    }

    static func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    /// Stable page IDs survive range growth and rotation. Empty data shows one page.
    static func months(in range: (start: Date, end: Date)?, fallback: Date) -> [Date] {
        guard let range else { return [startOfMonth(fallback)] }
        let interval = monthSpan(range)
        let last = startOfMonth(interval.end)
        var month = interval.start
        var result: [Date] = []
        while month <= last {
            result.append(month)
            guard let next = calendar.date(byAdding: .month, value: 1, to: month), next > month
            else { break }
            month = next
        }
        return result
    }
}
