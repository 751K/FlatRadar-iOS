import Foundation

/// 某一天有多少套房源起租，其中多少套**现在就能动手**。
///
/// 为什么要拆这两个数
/// ----------------
/// `CalendarPane` 里量过：691 条里 609 条是 Occupied（88%）——它们的
/// `available_from` 是未来的**退租日**，不是「现在能订」。只给一个总数的话，
/// 「这天 237 条」会被读成「237 套可以抢」，差了一个数量级。
///
/// 所以日历那一格上，柱子的**总高**是 `total`，实心的那一段是 `bookable`。
/// 一眼能看出「有很多，但能抢的没几套」——那正是这个 app 每天要回答的问题。
public nonisolated struct MoveInDay: Codable, Sendable, Equatable, Identifiable {

    /// `yyyy-MM-dd`，按服务端时区（``ServerTime/calendar``）算的那一天。
    public let day: String
    /// 这天起租的全部。
    public let total: Int
    /// 其中可订 + 抽签的。口径和 `CalendarPane.actionable` 一字不差。
    public let bookable: Int

    public var id: String { day }

    public init(day: String, total: Int, bookable: Int) {
        self.day = day
        self.total = total
        self.bookable = bookable
    }

    public var date: Date? { ServerTime.day(from: day) }

    /// 从日历的分组数据里切出**从今天起连续 `days` 天**的序列。
    ///
    /// 连续，是因为空着的那几天也在说话：柱子断掉的地方就是「这几天没房」。
    /// 只给有货的日子会把时间轴压缩成一排等距的柱子，读出来完全是另一件事。
    ///
    /// 用 ``ServerTime/calendar`` 推日子而不是 `Calendar.current`：后端按
    /// Europe/Amsterdam 分的桶，本地时区在月初会差一天（记忆里那条
    /// 「日期一律用 ServerTime」）。
    public static func series(listingsByDay: [String: [CalendarListing]],
                              from today: Date,
                              days: Int) -> [MoveInDay] {
        let cal = ServerTime.calendar
        let start = cal.startOfDay(for: today)
        return (0..<days).compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = dayKey(date)
            let items = listingsByDay[key] ?? []
            let bookable = items.filter {
                let kind = ListingStatus.from($0.status)
                return kind == .book || kind == .lottery
            }.count
            return MoveInDay(day: key, total: items.count, bookable: bookable)
        }
    }

    /// 序列里**第一个有货可抢**的那天。日历那一格的头条。
    ///
    /// 找的是 `bookable > 0` 而不是 `total > 0`：后者的第一个命中多半是一堆
    /// Occupied 的退租日，点进去什么也做不了。
    public static func nextBookable(in series: [MoveInDay]) -> MoveInDay? {
        series.first { $0.bookable > 0 }
    }

    nonisolated private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = ServerTime.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// `public`：小组件那边造示例数据要用它。造出来的 key 必须和
    /// ``series(listingsByDay:from:days:)`` 生成的完全一致，各写一份必然漂。
    public static func dayKey(_ date: Date) -> String { keyFormatter.string(from: date) }
}
