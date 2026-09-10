import SwiftUI
import FlatRadarCore

/// 列表页顶部那条统计带的数据。
///
/// 全部来自**已有的公开接口**，没有一个字段需要后端配合：
///
/// | 界面上的东西 | 来源 |
/// |---|---|
/// | `Total listings` | `GET /stats/public/summary` → `total` |
/// | `Status changes` | 同上 → `changes_24h` |
/// | `New today` | 同上 → `new_24h` |
/// | 折线 + 「vs. 14-day average」 | `GET /stats/public/charts/daily_new?days=14` |
/// | `scanned Nm ago` | 同上 summary → `last_scrape` |
///
/// 为什么单独一个 model 而不是塞进 ``BrowseModel``
/// -------------------------------------------
/// 它是**只读的展示数据**，跟窗口的查询状态（排序、筛选、选择）无关：换个排序
/// 不该重拉统计。分开之后 `BrowseModel` 的失效不会带着它一起重算。
///
/// 将来开多窗口时它是「可选共享缓存」那一层的候选（docs/MACOS.md 风险 6）——
/// 两个窗口各拉一份统计是浪费，但**现在不提前抽**：只有一个窗口，抽了也验证不了。
@MainActor
@Observable
final class SummaryModel {

    private let client = APIClient.shared

    private(set) var summary: MonitorStatus?
    /// 最近 14 天的每日新增。最后一个点是今天。
    private(set) var dailyNew: [ChartEntry] = []
    private(set) var isLoading = false

    /// 统计带拉失败**不弹错**，也不挡住表格。
    ///
    /// 它是锦上添花的一条信息带，房源表格才是这一屏的主体。统计挂了就把这条带
    /// 整个收起来，用户照样能用列表——而不是让一个次要接口的故障把主界面变成
    /// 一个错误页。
    private(set) var failed = false

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        failed = false
        async let s = try? client.getPublicSummary()
        async let c = try? client.getPublicChart(key: "daily_new", days: 14)
        let (summary, chart) = await (s, c)
        self.summary = summary
        self.dailyNew = chart?.data ?? []
        self.failed = (summary == nil)
        isLoading = false
    }

    // MARK: - 派生

    /// 今天的新增。
    var newToday: Int? { summary?.new24h }

    /// 除去今天之外的均值——「vs. 14-day average of 19」那个 19。
    ///
    /// **刻意排除最后一天**：拿今天去和「含今天的均值」比，今天自己会把基准
    /// 抬上去，涨幅被系统性地压小。样本不足 3 天就不给这个比较，宁可不显示
    /// 也不显示一个没有意义的百分比。
    var baselineAverage: Int? {
        let past = dailyNew.dropLast()
        guard past.count >= 3 else { return nil }
        let sum = past.reduce(0) { $0 + $1.count }
        return Int((Double(sum) / Double(past.count)).rounded())
    }

    /// 相对基准的涨跌，例如 `+63`。基准为 0 时返回 nil——除以零得不到有意义的百分比。
    var changeVsBaseline: Int? {
        guard let now = newToday, let base = baselineAverage, base > 0 else { return nil }
        return Int(((Double(now) - Double(base)) / Double(base) * 100).rounded())
    }

    /// 折线的取值序列。
    var sparkline: [Double] { dailyNew.map { Double($0.count) } }

    /// `scanned 4m ago`。拿不到就返回 nil，由界面省略整段，而不是显示 "unknown"。
    ///
    /// 用 `ServerTime.relativeTime` 而不是自己再写一份：那套解析要认六种日期格式、
    /// 还要固定在 Europe/Amsterdam 时区（后端就在那个时区），复制一份必然漂移。
    /// 这也是记忆里那条「日期一律用 ServerTime」的同一个理由。
    var scannedAgoText: String? {
        guard let raw = summary?.lastScrape, !raw.isEmpty, raw != "--" else { return nil }
        let text = ServerTime.relativeTime(raw)
        // 解析失败时 relativeTime 会把原串原样退回来——那不是给人看的，宁可不显示。
        return text == raw ? nil : text
    }
}
