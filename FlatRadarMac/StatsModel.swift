import SwiftUI
import FlatRadarCore

/// Stats 屏的数据层。
///
/// 这一屏在回答什么
/// --------------
/// **不是**"现在库存长什么样"。后端十三个图的 `days` 参数过滤的是
/// `first_seen`（`_listing_where()` 里就一句 `WHERE first_seen >= cutoff`），
/// 所以整屏的语义是**「过去 N 天首次出现的那批房源长什么样」**。
///
/// 实测这个差别很大：days=30 合计 347 套，而库存总数是 892。
/// 不说清楚的话，「Eindhoven 119」会被读成"现在 Eindhoven 有 119 套"，
/// 而实际是"上个月新上了 119 套"。所以屏幕顶上那句话是**必需的**，不是装饰。
///
/// 和列表屏那条 ``StatsStrip`` 的分工：strip 回答"现在库存怎么样"
/// （892 套、24 小时变动、匹配你筛选的），这一屏回答"新上的那批什么样"。
/// 两个问题，不重复。
@MainActor
@Observable
final class StatsModel {

    /// 时间窗。后端 clamp 在 1–365。
    ///
    /// 给到 90 天是因为这个房源市场有明显的月初旺季（实测 9-02 一天上了 60 套，
    /// 9-07 上了 37 套），7/14/30 三档都跨不过两个月初，看不出那是周期还是偶然。
    enum Window: Int, CaseIterable, Identifiable {
        case week = 7, twoWeeks = 14, month = 30, quarter = 90
        var id: Int { rawValue }
        var label: String { "\(rawValue)d" }
    }

    var days: Window = .month {
        didSet { guard days != oldValue else { return }; Task { await load(force: true) } }
    }

    private(set) var charts: [String: [ChartEntry]] = [:]
    private(set) var isLoading = false
    private(set) var failed = false

    /// 这一屏铺哪几张图，**按阅读顺序**。
    ///
    /// 顺序是一条线索：先"每天来多少"（两张时序），再"来的这些现在怎么样了"
    /// （status——这是整屏最有信息量的一张：上个月新上的 347 套里 281 套已经
    /// Occupied 了），然后是房子本身的属性，最后才是"什么时候上架"这种
    /// 偏内部的节奏。
    ///
    /// **`contract_dist` 不在里面**：线上只有一个值（`Indefinite`），
    /// 画一根柱子等于用一张图说"没有信息"。
    static let keys: [String] = [
        "daily_new", "daily_changes",
        "status_dist",
        "price_dist", "area_dist", "type_dist", "energy_dist", "floor_dist",
        "city_dist", "source_dist", "tenant_dist",
        "hourly_dist",
    ]

    /// 这一批一共多少套。
    ///
    /// 取 `status_dist` 的合计：**每套房都有状态**，而价格 / 面积那几张会把
    /// 读不出值的那些丢掉，拿它们当分母会少算。
    var sampleSize: Int {
        (charts["status_dist"] ?? []).reduce(0) { $0 + $1.count }
    }

    func load(force: Bool = false) async {
        guard force || charts.isEmpty else { return }
        guard !isLoading else { return }
        isLoading = true
        failed = false
        let window = days.rawValue

        // 十二个请求一起发。都是公开接口（`bearer_optional`），互不依赖，
        // 串行发的话最慢的那个会把整屏拖到十几倍的等待。
        var fetched: [String: [ChartEntry]] = [:]
        await withTaskGroup(of: (String, [ChartEntry]?).self) { group in
            for key in Self.keys {
                group.addTask {
                    let chart = try? await APIClient.shared.getPublicChart(key: key, days: window)
                    return (key, chart?.data)
                }
            }
            for await (key, data) in group {
                guard let data else { continue }
                // 合并 + 排序在包里（``ChartPresentation``），两端同一份。
                fetched[key] = ChartPresentation.display(data, forKey: key)
            }
        }

        // **一张都没拿到才算失败。** 拿到一半就画一半——十二张图里某一张
        // 挂了不该让整屏变成错误页，而 `getPublicChart` 对未知 key 会 404，
        // 后端加减图表时也不该整屏炸。
        if fetched.isEmpty {
            failed = true
        } else {
            charts = fetched
        }
        isLoading = false
    }
}

/// Stats 屏选中的那张图，交给右栏列明细。
///
/// 存**整份数据**而不是只存 key、让 `InspectorPane` 自己回 `StatsModel` 去查：
/// 和 ``BrowseModel/calendarDay`` 存 `CalendarDay` 是同一个理由——右栏是三屏
/// （现在四屏）共用的，多认一个 model 就多一层耦合。
struct StatsSelection: Equatable {
    let key: String
    let title: String
    let entries: [ChartEntry]

    var total: Int { entries.reduce(0) { $0 + $1.count } }

    static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.entries.count == b.entries.count && a.total == b.total
    }
}
