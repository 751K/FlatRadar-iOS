import SwiftUI
import Charts
import FlatRadarCore

/// 一张统计图。
///
/// 两种形状，按**标签读不读得下**分，不按数据类型分：
///
/// - **竖柱**：标签短（日期 `09-17`、价格区间、`A+`、`03:00`）且有序。
///   竖着排能一眼看出"从低到高"的形状，那正是有序维度的全部意义。
/// - **横条**：标签是名字（`Eindhoven`、`OurCampus Amsterdam Diemen`、
///   `student and employed`）。这种标签竖着放要么转 90 度要么被截断，
///   横着排每条自己占一行，多长都读得完。
///
/// 判据在包里的 ``ChartPresentation/shape(for:)``。它和 ``ChartPresentation/Axis``
/// （决定排序）是**两个独立的问题**——`status_dist` 正好两边不一样：它有业务顺序
/// 所以不许重排，但标签是名字所以要横条。
struct ChartCard: View {

    let key: String
    let title: String
    let caption: String?
    let entries: [ChartEntry]
    let isSelected: Bool
    /// 跨整行的那两张时序图。高一点，因为横向被拉长了，太扁会看不出起伏。
    let wide: Bool
    let onSelect: () -> Void

    private var axis: ChartPresentation.Axis { ChartPresentation.axis(for: key) }
    private var shape: ChartPresentation.Shape { ChartPresentation.shape(for: key) }

    /// 卡里画的那几条。城市有 20 个，截到 8；其余全画。
    private var shown: [ChartEntry] {
        Array(entries.prefix(StatsCopy.cardLimit(key)))
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                head
                chart
                    .frame(height: wide ? 150 : 132)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // `GroupBox` 的那层底，不是 iOS 那种"卡片浮起"。
            // docs/DESIGN.md §6：分组底 + 卡片浮起是 iOS 的成语，
            // Mac 的成语是窗口底 + 内嵌的盒子。所以只有极淡的底和描边，没有投影。
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Theme.ink.opacity(0.55)
                                             : Color.primary.opacity(0.07),
                                  lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(entries.count) \(axis == .time ? "days" : "categories")")
        .accessibilityHint("Shows the full breakdown in the inspector")
    }

    private var head: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - 图

    @ViewBuilder
    private var chart: some View {
        switch shape {
        case .verticalBars:
            // 时间轴走**连续**坐标（`Date` / 小时数），不是字符串分类轴。
            // 理由见 `timeBars` 的注释——这是刻度能抽稀的前提。
            if axis == .time { timeBars } else { verticalBars }
        case .horizontalBars:
            horizontalBars
        }
    }

    /// 时序图：x 是真正的 `Date`（或小时数），不是字符串。
    ///
    /// **这是刻度能抽稀的前提。** 第一版把日期当字符串画，Charts 于是按
    /// **分类轴**处理——分类轴一根柱子标一个刻度，`AxisMarks(values:)` 给一个
    /// 子集也不管用（试过，31 个标签照旧全画）。实拍出来 `08-1808-1908-20…`
    /// 糊成一条蓝带，窗口一窄更明显。
    ///
    /// 换成连续轴之后，`.automatic(desiredCount:)` 才真的起作用，而且日期格式
    /// 交给系统（会跟随用户的地区设置），不用自己截 `String(suffix(5))`。
    @ViewBuilder
    private var timeBars: some View {
        if key == "hourly_dist" {
            Chart(shown) { entry in
                BarMark(x: .value("Hour", Int(entry.label) ?? 0),
                        y: .value("Count", entry.count))
                .foregroundStyle(Theme.chart)
                .cornerRadius(2)
            }
            .chartYAxis { countAxis }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        Text(String(format: "%02d:00", value.as(Int.self) ?? 0))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            // 0…23 是闭区间。不写死的话只有有数据的那几个小时上轴，
            // 而"凌晨三点集中上架"这件事恰恰要靠空着的那些小时才看得出来。
            .chartXScale(domain: 0...23)
        } else {
            Chart(shown) { entry in
                if let day = ServerTime.day(from: entry.label) {
                    BarMark(x: .value("Date", day, unit: .day),
                            y: .value("Count", entry.count))
                    .foregroundStyle(Theme.chart)
                    .cornerRadius(2)
                }
            }
            .chartYAxis { countAxis }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) {
                    AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 两三条网格线。这些卡只有 130pt 高，五条刻度线会把图压成横格纸。
    private var countAxis: AxisMarks<some AxisMark> {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
            AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
            AxisValueLabel().font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var verticalBars: some View {
        VStack(spacing: 3) {
            if labelsFitOnAxis {
                orderedBars.chartXAxis {
                    AxisMarks {
                        AxisValueLabel().font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            } else {
                // **整条轴关掉**，不是"给 `AxisMarks` 一个空数组"。
                //
                // 这里踩的是和日期标签同一个坑：分类轴（x 是字符串）根本不看
                // `AxisMarks(values:)`——给子集不认，给空数组也不认，照旧一根柱子
                // 标一个。第一版写的 `AxisMarks(values: axisLabels)` 在 `axisLabels`
                // 算出 `[]` 时什么也没关掉，实拍是九个价格区间糊成
                // `<€600€600-70€700-800…` 一条，**底下还叠着**本该替代它们的端点。
                orderedBars.chartXAxis(.hidden)
                endpointCaption
            }
        }
    }

    private var orderedBars: some View {
        Chart(shown) { entry in
            BarMark(
                x: .value("", ChartPresentation.shortLabel(entry.label, forKey: key)),
                y: .value("Count", entry.count))
            .foregroundStyle(color(entry))
            .cornerRadius(2)
        }
        .chartYAxis { countAxis }
    }

    /// 两个端点：`<€600 … >€1600`。
    ///
    /// 价格有 9 档，每个标签九个字符——282pt 宽的卡里并排画出来是
    /// `<€600 €600-7(0)0-8(0)0-9…` 一团糊（实拍过）。
    ///
    /// 改成只写首尾，是**照 iOS 那张价格卡的做法**（`sorted.first?.label` /
    /// `sorted.last?.label` 写在柱子下面）：这张卡回答的本来就是"钱堆在哪一段"，
    /// 形状说得清；具体哪根柱子是哪一档，右栏的明细表里有确切数字。
    private var endpointCaption: some View {
        HStack(spacing: 0) {
            Text(shown.first?.label ?? "")
            Spacer(minLength: 4)
            Text(shown.last?.label ?? "")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    /// 有序轴（价格 / 面积 / 楼层 / 能效）上的标签排得下吗。
    /// 规则本身在包里（``ChartPresentation/axisLabelsFit(_:within:)``），
    /// 这里只负责给它一个宽度。
    private var labelsFitOnAxis: Bool {
        guard axis == .ordered else { return true }
        return ChartPresentation.axisLabelsFit(
            shown.map { ChartPresentation.shortLabel($0.label, forKey: key) },
            within: Self.assumedNarrowWidth)
    }

    /// 估算用的绘图区宽度：最窄那一列（``StatsPane`` 的 320pt）减掉 y 轴和内边距。
    ///
    /// **不量真实宽度。** 试过：`.background` 里挂 `onGeometryChange` 读 `Chart`
    /// 的宽度，一次都没落地（Charts 在布局上隔了一层）。这里也不需要精确——
    /// 判据只是"九个价格区间排不排得下"，宽卡上偶尔少标几个刻度是可以接受
    /// 的那一边。
    private static let assumedNarrowWidth: CGFloat = 250

    /// 横条**不走 Swift Charts**，一行一条自己画。
    ///
    /// 原来用 `BarMark(x: count, y: label)`，实拍出来 City 那张是一堆细线穿过
    /// 文字。原因是 Charts 的分类轴把标签**单独占一行**摆在条子上方，
    /// 一个分类吃掉两行高度——两张卡同样 132pt 高：
    ///
    /// | 卡 | 条数 | 一格 | 结果 |
    /// |---|---|---|---|
    /// | Type | 4 | 33pt | 标签 12pt + 条子 10pt，好好的 |
    /// | City | 8 | 16pt | 标签占掉 12pt，条子只剩 4pt，压在字上 |
    ///
    /// 所以这不是调参能救的——是**一个分类两行**这个排法在 8 条上超预算。
    /// 换成自己画的行之后标签、条子、数字共用一行，8 条在 132pt 里每行还有
    /// 近 15pt。顺带解决两件：
    ///
    /// - 数字不再用 `.annotation` 挂在条子末端。那玩意撞下一行的标签，
    ///   实拍里 `119` 正压在 `Amsterdam` 上。现在是右对齐的一列。
    /// - 长名字（`OurCampus Amsterdam Diemen`）能用满整行宽，不必挤在轴的
    ///   那条窄栏里。
    ///
    /// 底纹这个画法和右栏明细表是同一个（``InspectorPane`` 的 `breakdownRow`）：
    /// 点一张卡跳到右栏，看到的是同一个东西的长版本，不用重新认。
    private var horizontalBars: some View {
        GeometryReader { geo in
            let n = CGFloat(max(shown.count, 1))
            // 条数少的卡不要把行撑到 33pt——那是"一行字配一大片留白"。
            // 26pt 封顶，剩下的高度留空。
            let row = min(26, (geo.size.height - Self.rowGap * (n - 1)) / n)
            VStack(spacing: Self.rowGap) {
                ForEach(shown) { barRow($0, height: row) }
                Spacer(minLength: 0)
            }
        }
    }

    private static let rowGap: CGFloat = 2

    /// 条子按**最长的那条**撑满，不是按总数的占比。
    ///
    /// 这张卡回答的是"谁最多、差多少"，满宽给峰值才看得出差距；
    /// 占比是右栏的事，那里有确切的百分数。
    private var peak: Int { shown.map(\.count).max() ?? 0 }

    private func barRow(_ entry: ChartEntry, height: CGFloat) -> some View {
        let share = peak > 0 ? Double(entry.count) / Double(peak) : 0
        return HStack(spacing: 6) {
            Text(ChartPresentation.shortLabel(entry.label, forKey: key))
                .lineLimit(1)
                // 从**头**截，理由同右栏：城市名前缀常常一样
                // （`Amsterdam Naritaweg` / `Amsterdam Diemen`），从尾截会把
                // 唯一能区分它们的那一段切掉。
                .truncationMode(.head)
            Spacer(minLength: 4)
            Text("\(entry.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .padding(.horizontal, 5)
        .frame(height: height)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(entry).opacity(0.22))
                    // 至少 2pt：只有 1 条的平台（OurDomain）也得看得见自己那一条，
                    // 否则那一行只剩一个孤零零的数字。
                    .frame(width: max(2, geo.size.width * share))
            }
        }
    }

    /// 语义色优先，没有就用统计带那个蓝（``Theme/chart``），全 App 一个蓝。
    private func color(_ entry: ChartEntry) -> Color {
        ChartPresentation.color(forKey: key, label: entry.label) ?? Theme.chart
    }
}
