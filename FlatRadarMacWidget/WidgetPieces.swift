import SwiftUI
import WidgetKit
import FlatRadarCore

// 两格小组件共用的东西：时间轴、以及几块反复出现的排版。

// MARK: - 时间轴

/// `nonisolated` 和下面的 provider 是一起的：`Entry` 是 `TimelineProvider` 的
/// 关联类型，它要是主 actor 隔离的，整个 conformance 就跟着被拖过去，
/// provider 那边单独标 `nonisolated` 也没用（错误信息是
/// 「conformance ... crosses into main actor-isolated code」，指的正是这里）。
nonisolated struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// `nil` = 共享容器里什么都没有：这台 Mac 还没跑过 app，或者刚登出。
    let snapshot: WidgetSnapshot?
}

/// 两格共用一个 provider：它们读的是**同一份**快照，区别只在画哪几个字段。
nonisolated struct SnapshotProvider: TimelineProvider {

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample)
    }

    /// 小组件图库里那一格的预览。`context.isPreview` 时给示例数据而不是真数据：
    /// 用户还没把它摆上桌面，这时候给一个 `—` 的空格子，看起来就像坏的。
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let real = WidgetBridge.read()
        completion(SnapshotEntry(date: Date(),
                                 snapshot: context.isPreview ? (real ?? .sample) : real))
    }

    /// 一次给足接下来 24 小时的条目。
    ///
    /// 为什么要给这么多：这一格的文字**自己会变旧**（`4m ago` → `5m ago`），
    /// 而 WidgetKit 不会主动重画——每一次该变的时刻都得在时间轴里列出来。
    /// 具体给哪些时刻是 ``WidgetSnapshot/refreshPoints(from:)`` 的事，它按
    /// ``ServerTime`` 的分档走。
    ///
    /// 数据本身在这 24 小时里**不会变**：这一格不联网，新数据只能由 app 写进来，
    /// 而 app 写完会自己踢一次时间轴（``WidgetBridge/publish(_:)``）。所以每个
    /// 条目挂的是同一份快照，变的只是"现在几点"。
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetBridge.read()
        let points = (snapshot ?? .placeholder(at: now)).refreshPoints(from: now)
        let entries = points.map { SnapshotEntry(date: $0, snapshot: snapshot) }
        // 24 小时后再问一次。真正的更新走 app 那条主动踢的路，这里只是兜底：
        // 万一 app 一直没跑，至少那行 `checked 2d ago` 还会往前走。
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(24 * 3600))))
    }
}

nonisolated extension WidgetSnapshot {
    /// 图库预览和占位用的示例。数字取自设计稿那张图和实测值。
    ///
    /// `lastScrape` 用 `ISO8601Format()` 现算而不是写一个固定串：写死的话预览里
    /// 那行字会是 `scanned 412d ago`，看起来像坏的。
    static var sample: WidgetSnapshot {
        let now = Date()
        let cal = ServerTime.calendar
        let start = cal.startOfDay(for: now)
        // 88% 是 Occupied——这是 CalendarPane 实测的比例，示例数据也照着它编，
        // 否则预览里柱子全是实心的，看不出"能抢的其实没几套"这件事。
        let shape = [0, 0, 3, 1, 0, 0, 9, 2, 0, 0, 0, 14, 0, 1,
                     0, 0, 7, 0, 0, 22, 0, 0, 0, 4, 0, 0, 11, 0]
        let days = shape.enumerated().compactMap { offset, total -> MoveInDay? in
            guard let date = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            return MoveInDay(day: MoveInDay.dayKey(date), total: total,
                             bookable: total >= 7 ? max(1, total / 6) : 0)
        }
        return WidgetSnapshot(
            newToday: 31,
            dailyNew: [12, 19, 8, 22, 17, 14, 25, 11, 16, 20, 9, 23, 18, 31],
            totalListings: 892,
            statusChanges: 47,
            matchCount: 193,
            isFiltered: true,
            unreadAlerts: 3,
            showsUnread: true,
            moveIns: days,
            lastScrape: now.addingTimeInterval(-4 * 60).ISO8601Format(),
            capturedAt: now)
    }
}

// MARK: - 排版

/// 展示数字那一档的磅值。
///
/// 44pt 是这套界面里写死磅值的三个例外之一（见 ``Theme`` 的字号一节）：统计带、
/// 菜单栏、日历、Alerts 用的都是它。小组件是同一件事的第五个位置，同一档。
///
/// 小号那一格只有 128pt 可用宽，五位数会顶到边，所以配 `minimumScaleFactor`——
/// 缩而不是截：一个被截掉最后一位的数字是**错的**，小一号的还是对的。
struct DisplayNumber: View {
    let text: String
    var size: CGFloat = 44
    var dimmed = false

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .tracking(size * -0.032)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }
}

/// 「标签 — 数字」一行。大号和中号右边那几行都是它。
///
/// 标签在左、数字右对齐：竖着排好几行时，右对齐的数字才扫得出大小关系，
/// 左对齐的话不同位数会参差。
struct MetricRow: View {
    let title: String
    let value: Int?
    /// 口径限定语，跟在标题后面用更浅的一档写。
    ///
    /// 统计带那边的 `metric(title:value:caption:)` 是同一件事（`all platforms`
    /// / `last 24h`）——一个数只要和另一个同名的数**统计范围不同**，范围就得写在
    /// 脸上。日历那格的两档尺寸正是这种情况：中号铺两周、大号铺四周，
    /// 不写的话同一个 `Move-ins` 在两格上是 30 和 74。
    var caption: String?
    var dimmed = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 4)
            Text(StatusWording.countText(value))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }
}

/// 涨跌那一小块：`+63%`。
///
/// 涨用能效最高档那个深绿、跌用次要色，**不用红**——房源变少不是错误，
/// 红色会被读成告警。和统计带（``StatsStrip/anchor``）同一个判断。
struct ChangeBadge: View {
    let percent: Int

    var body: some View {
        Text(StatusWording.percent(percent))
            .font(.callout.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(percent >= 0 ? AnyShapeStyle(Color.energyTop)
                                          : AnyShapeStyle(.secondary))
    }
}

/// 未读那个小胶囊。
///
/// **不用红**，理由同上：这套界面里颜色是用来编码信息的（七个平台色 + 五个状态
/// 色），再塞一个红进来只会和它们抢。用中性填充 + 主色数字，靠形状而不是色相
/// 把它从周围的说明文字里分出来。
///
/// 访客和 0 未读都不画：访客的个人通知流是关的，那个数永远是 0，
/// 摆一个常驻的 `0` 只会让人以为坏了。
struct UnreadPill: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel("\(count) unread alerts")
    }
}

/// 底下那行小字。新鲜说 `scanned`，过期改口说 `checked`——见
/// ``WidgetSnapshot/footnote(at:)``，那是这套小组件最要紧的一条规矩。
struct Footnote: View {
    let entry: SnapshotEntry

    var body: some View {
        Text(entry.snapshot?.footnote(at: entry.date) ?? StatusWording.openApp)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// 一排柱子。
///
/// 没有坐标轴、没有网格、没有图例——和 ``Sparkline`` / Alerts 那 12 根柱子同一条
/// 规则（设计稿 t2「去线留白」）。柱子回答的是形状问题（"最近是多还是少"
/// "哪几天有货"），不是读数问题；要读数的话旁边就有数字。
///
/// 柱宽封顶 10pt
/// ------------
/// 第一版让柱子平分整条宽度（14 根摊在 297pt 里，每根 18pt），画出来是一排
/// **药丸**不是柱状图——`Capsule` 在那个宽高比下圆角吃掉了整个形状，矮的那几根
/// 直接成了圆点。封顶之后柱子是柱子，多出来的空间变成柱间距。
///
/// 圆角也从 `Capsule` 换成固定 2pt：`Capsule` 的圆角跟着**宽度**走，
/// 而这排柱子的高度差了 20 倍，同一个圆角在最矮那根上就是一个整圆。
struct BarRow: View {
    /// 每根柱子的原始值，归一化在内部做。
    let values: [Int]
    /// 叠在底部的实心段（日历那格的 bookable）。空数组 = 不画。
    var solid: [Int] = []
    /// 整根染成强调色的那一根（状态那格的"今天"）。
    var highlight: Int?
    /// 只在柱子**底下**打一个记号的那一根（日历那格的"下一个能抢的日子"）。
    ///
    /// 和 `highlight` 分开是因为日历那一格里蓝色**已经有含义了**（实心段 =
    /// 能抢的）。再用蓝色整根染一遍，同一个颜色在同一张图里说两件事，
    /// 而那正是这套设计反复在避免的（「有颜色的地方就是有信息的地方」）。
    var tick: Int?
    /// 柱宽封顶。窄的那一列（日历中号）给 8，整幅宽的给 10。
    var barWidth: CGFloat = 10

    private static let radius: CGFloat = 2
    /// 值大于 0 时柱子至少这么高——否则 22 里的 1 只有 2.5pt，和"这天没有"
    /// 长得一模一样，而两者说的是相反的事。
    private static let minVisible: CGFloat = 3

    private var peak: Int { max(values.max() ?? 0, 1) }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        bar(value: value,
                            solid: index < solid.count ? solid[index] : 0,
                            filled: index == highlight,
                            height: proxy.size.height)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            if tick != nil {
                ticks
            }
        }
    }

    private func bar(value: Int, solid solidValue: Int, filled: Bool, height: CGFloat) -> some View {
        let scale = { (v: Int) in
            v <= 0 ? 0 : max(height * CGFloat(v) / CGFloat(peak), Self.minVisible)
        }
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(filled ? AnyShapeStyle(Color.chartTint) : AnyShapeStyle(.quaternary))
                // 值为 0 的日子也留一条 2pt 的底线：断成空白的话，
                // "这天没有" 和 "这排到此为止" 看起来是一样的。
                .frame(height: max(scale(value), 2))
            if solidValue > 0 {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Color.chartTint)
                    .frame(height: scale(solidValue))
            }
        }
        .frame(width: barWidth)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// 被点名那一天底下的一小段横线。只有一根，所以不需要图例。
    private var ticks: some View {
        HStack(spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, _ in
                Group {
                    if index == tick {
                        Capsule().fill(Color.chartTint).frame(width: barWidth, height: 2)
                    } else {
                        Color.clear.frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 2)
    }
}

extension Color {
    /// 两张迷你图的颜色。
    ///
    /// 写 `.blue` 而不是抄 hex，理由在 ``Theme/chart`` 里写全了：两端实测
    /// `Color.blue` 解析出来是同一个值（浅 `#0088FF` / 深 `#0091FF`），
    /// 而抄 hex 会在下一次 Apple 调整 systemBlue 时把两端钉在不同的代上。
    /// 小组件够不到 `Theme`（那是 app target 的），但**值是同一个**。
    static var chartTint: Color { .blue }
}
