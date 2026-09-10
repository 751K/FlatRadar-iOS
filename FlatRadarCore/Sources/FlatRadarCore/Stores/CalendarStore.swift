import Foundation

/// 日历视图状态机：拉取 + 按日分组。
///
/// 月历界面需要"某一天有多少套可入住"的快速查询，原始列表 O(N) 太慢。
/// fetch 完成后立刻 build ``listingsByDay``（dict[yyyy-MM-dd → [Listing]]），
/// 视图渲染日单元格时 O(1) 查 count。
@MainActor
@Observable
public final class CalendarStore {

    /// 隐式 init 随 `public` 一起变成 internal，宿主 app 构造不了。
    /// 这些 store 的属性全有默认值，空实现与迁移前的隐式构造等价。
    public init() {}
    public var listings: [CalendarListing] = []
    /// 按日归组，key 是 `yyyy-MM-dd`。
    ///
    /// `public` 是为 Mac 端的月网格开的：它要一次铺 42 个格子，每格问一次
    /// ``listings(on:)`` 也行，但那是 42 次字典查 + 42 次 `DateFormatter`
    /// 格式化；直接把算好的这份给出去省掉后者。内容是同一批公开的
    /// ``CalendarListing``，没有额外泄露什么。
    public var listingsByDay: [String: [CalendarListing]] = [:]
    public var isLoading = false
    public var errorMessage: String?
    public var lastError: APIError?

    private let client = APIClient.shared

    /// 数据范围：第一个 / 最后一个可入住日期；UI 限制月份切换不超出。
    public var dateRange: (start: Date, end: Date)? {
        let dates = listings.compactMap(\.date)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        return (first, last)
    }

    public func fetch() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let resp = try await client.getCalendar()
            listings = resp.listings
            listingsByDay = Dictionary(grouping: listings, by: \.dayKey)
        } catch {
            // 被取消不是失败——见 Error.isCancellation。
            if !error.isCancellation {
                lastError = error as? APIError
                errorMessage = error.localizedDescription
            }
            #if DEBUG
            print("[CalendarStore] fetch error: \(error)")
            #endif
        }
    }

    public func refresh() async {
        await fetch()
    }

    /// 登出时清空——下个用户日历应该重新加载。
    public func clear() {
        listings = []
        listingsByDay = [:]
        isLoading = false
        errorMessage = nil
        lastError = nil
    }

    /// 某个日期所属当天的可入住房源列表。
    public func listings(on date: Date) -> [CalendarListing] {
        let key = Self.dayKey(for: date)
        return listingsByDay[key] ?? []
    }

    /// 用作 dict key 的 yyyy-MM-dd（与后端 ``available_from`` 前 10 位对齐）。
    static func dayKey(for date: Date) -> String {
        Self.formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
