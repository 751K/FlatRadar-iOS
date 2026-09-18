import SwiftUI

/// 一张统计图**怎么排**和**怎么上色**。
///
/// 为什么在包里
/// -----------
/// 两件事都是**数据的属性，不是某一端的界面口味**：
///
/// - 「价格区间不能按数量排序」对 iPhone 和 Mac 一样成立；
/// - 「同一个平台在任何图表下都是同一个颜色」是 docs/DESIGN.md §1.2 写死的规则，
///   原话里就有"任何图表"四个字。
///
/// 各写一份的下场这个项目已经见过好几次了（`RowSurface` 三处、`PlaceSummary` 四处）。
public nonisolated enum ChartPresentation {

    // MARK: - 轴的类型

    /// 这张图的横轴是什么。决定**能不能按数量重排**。
    public enum Axis: Sendable {
        /// 时间轴：`daily_new` / `daily_changes` / `hourly_dist`。
        case time
        /// 有序的分档：价格区间、面积区间、楼层、能效等级。
        /// **重排就毁了**——这条轴本身在传达"从低到高"。
        case ordered
        /// 无序的分类：城市、平台、状态、房型、租客类型。按数量排才好读。
        case categorical
    }

    public static func axis(for key: String) -> Axis {
        switch key {
        case "daily_new", "daily_changes", "hourly_dist":
            return .time
        // `status_dist` 在这里而不是 `.categorical`：它有**业务顺序**
        // （可订 > 抽签 > 已预订 > 已占），`bucketed(forKey:)` 已经按那个顺序
        // 排好了，再按数量重排会把"最值得看的那一档"推到最后——而那一档
        // 往往最小（实测能订的 17 条、已占 311 条）。
        // 这和地图标记取 `leadStatus` 是同一条判断：一栋楼里 1 套可订 11 套已租，
        // 标记该是绿的。
        case "price_dist", "area_dist", "floor_dist", "energy_dist", "status_dist":
            return .ordered
        default:
            return .categorical
        }
    }

    // MARK: - 画成什么形状

    /// 柱子横着还是竖着。
    ///
    /// **和 ``Axis`` 是两个问题**，第一版把它们合成了一个，撞在 `status_dist`
    /// 上：它要"别重排"（所以 axis 是 `.ordered`），但要横条（因为标签是
    /// `Available to book` 这种名字）。合在一起的话，改对一个就改坏另一个。
    public enum Shape: Sendable {
        /// 竖柱。标签短且有序时用——`09-17` / `€600-700` / `A+` / `03:00`。
        /// 竖着排能一眼看出"从低到高"的形状，那正是有序维度的全部意义。
        case verticalBars
        /// 横条。标签是**名字**时用——`Eindhoven`、`OurCampus Amsterdam Diemen`、
        /// `student and employed`。这种标签竖着放要么转 90 度要么被截断，
        /// 横着每条自己占一行，多长都读得完。
        case horizontalBars
    }

    public static func shape(for key: String) -> Shape {
        switch key {
        case "city_dist", "source_dist", "status_dist", "type_dist", "tenant_dist":
            return .horizontalBars
        default:
            return .verticalBars
        }
    }

    /// 拿到手就能画的那一份：先做语义合并，再**只给该排的排**。
    ///
    /// ⚠️ 这个函数存在的全部理由，是上游有一处正好做反了。
    /// iOS 的 `ChartDetailView` 写的是
    ///
    ///     let sorted = isTime ? chart.data.reversed()
    ///                         : chart.data.sorted { $0.count > $1.count }
    ///
    /// ——除时间轴外**一律按数量降序**。于是价格分布在那张明细表里长这样：
    ///
    ///     €1000-1200(85), €1200-1400(55), €1400-1600(52), >€1600(46),
    ///     €800-900(45), €900-1000(38), €700-800(26), <€600(0), €600-700(0)
    ///
    /// 一条乱序的价格轴。同一个 app 里 Dashboard 的价格卡却是升序的
    /// （`priceSortedAsc`）——两处对同一份数据给了两种顺序。
    ///
    /// 顺带一提：**后端返回的顺序本来就是对的**。有序维度按分档顺序发，
    /// 无序维度带 `ORDER BY cnt DESC`。真正需要客户端排的只有 `type_dist`
    /// ——它要先合并（`"1"/"2"/"3"` → `Apt`）才谈得上顺序。
    public static func display(_ data: [ChartEntry], forKey key: String) -> [ChartEntry] {
        let merged = data.bucketed(forKey: key)
        switch axis(for: key) {
        case .time, .ordered:
            return merged
        case .categorical:
            return merged.sorted { $0.count > $1.count }
        }
    }

    // MARK: - 颜色

    /// 这一条用什么颜色。返回 `nil` 表示"没有语义色，用图表的默认色"。
    ///
    /// 三类有语义色，因为它们在别处已经有了，图表必须跟着走：
    /// 状态胶囊、平台徽章、能效字母。用户是靠颜色认出它们的，图里换一套
    /// 等于让同一个东西在两个地方长得不一样。
    public static func color(forKey key: String, label: String) -> Color? {
        switch key {
        case "status_dist":
            return ListingStatus.from(label).color
        case "source_dist":
            return Platform.color(label)
        case "energy_dist":
            return energyColor(label)
        default:
            return nil
        }
    }

    /// 能效条的颜色。**和表格里那一列的规则不同，这是有意的。**
    ///
    /// 表格（Mac 的 `EnergyStyle`）只给 A 档上色，B 及以下用正文色——
    /// 一列里出现黄橙红会读成"这些房源有问题"，而能效 C 只是普通。
    ///
    /// 图表反过来：一张条形图的职责就是把所有档次区分开，全用一个颜色
    /// 等于没画。所以 B/C/D 这里给系统色。
    ///
    /// A 档三个绿色走 Asset Catalog 的语义 token（有亮/暗双值）；
    /// B 以下走 SwiftUI 系统色（本身已自适应）。包里暂时没有 B–G 的 token，
    /// 要加的话先往 `Colors.xcassets` 里加，别在调用方硬编码 RGB。
    private static func energyColor(_ label: String) -> Color {
        switch energyRank(label) {
        case 0, 1: return .energyTop      // A+++ / A++
        case 2:    return .energyAPlus    // A+
        case 3:    return .energyA        // A
        case 4:    return .yellow         // B
        case 5:    return .orange         // C
        default:   return .red            // D 及以下
        }
    }

    /// `A+++`=0、`A++`=1、`A+`=2、`A`=3、`B`=4 …… 认不出的排到最后。
    ///
    /// 注意 `bucketed(forKey:)` 会先把 A+ 以上合并成 `A+`，所以图上实际只会
    /// 出现 2 及以后；0/1 留着是为了这个函数单独用也对。
    static func energyRank(_ label: String) -> Int {
        let cleaned = label.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = cleaned.first else { return 99 }
        if first == "A" {
            let pluses = cleaned.dropFirst().prefix { $0 == "+" }.count
            return 3 - min(pluses, 3)
        }
        guard let index = "BCDEFG".firstIndex(of: first) else { return 99 }
        return 4 + "BCDEFG".distance(from: "BCDEFG".startIndex, to: index)
    }

    // MARK: - 标签

    /// 轴上显示的短标签。
    ///
    /// 日期只留 `MM-DD`（完整的 `2026-09-17` 在轴上排不下），小时补成 `03:00`，
    /// 状态名剥到核心词（`Available to book` 在一根 60pt 宽的柱子下面必被截断）。
    public static func shortLabel(_ label: String, forKey key: String) -> String {
        switch key {
        case "daily_new", "daily_changes":
            // `2026-09-17` → `09-17`
            return label.count >= 10 ? String(label.suffix(5)) : label
        case "hourly_dist":
            // 后端发的是 `0`…`23`
            return label.count <= 2 ? String(format: "%02d:00", Int(label) ?? 0) : label
        case "status_dist":
            return ListingStatus.from(label).shortChartLabel
        default:
            return label
        }
    }

    // MARK: - 轴上排不排得下

    /// 有序轴（价格 / 面积 / 楼层 / 能效）上的那排标签，`width` 点宽里放得下吗。
    ///
    /// 放不下时的正确做法是**整条轴关掉**，改在图下面写首尾两个端点，
    /// 而**不是抽稀**：价格轴上只标第 1、4、7 档的话，读者得自己数格子才知道
    /// 第 5 根柱子是哪一档。
    ///
    /// 判据按**字符总数**而不是条数：`floor_dist` 四档（`Ground` / `1-2` /
    /// `3-5` / `6+`）和 `price_dist` 九档（每档九个字符）差的不是条数是长度。
    ///
    /// 估得准不准不要紧，**估错方向才要紧**：拿不准时要假设窄。少标几个刻度
    /// 只是少几个刻度；多标是一整条读不出来的糊带。
    public static func axisLabelsFit(_ labels: [String], within width: CGFloat) -> Bool {
        // caption2 在 macOS 上是 10pt，西文平均约 5.5pt 一个字符；
        // 再给每个标签留 8pt 间隙，免得两个贴在一起。
        let total = labels.reduce(CGFloat.zero) { $0 + CGFloat($1.count) * 5.5 + 8 }
        return total <= width
    }
}

nonisolated extension ListingStatus {
    /// 图表轴上用的短名。`label` 是给人读的完整说法，轴上放不下。
    var shortChartLabel: String {
        switch self {
        // 查表：这几个词是统计页状态分布图的轴标签，原先在任何语言下都是英文。
        case .book:     return String(localized: "Book", bundle: .module)
        case .lottery:  return String(localized: "Lottery", bundle: .module)
        case .reserved: return String(localized: "Reserved", bundle: .module)
        case .occupied: return String(localized: "Occupied", bundle: .module)
        case .other:    return String(localized: "Other", bundle: .module)
        }
    }
}
