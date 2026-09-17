import SwiftUI
import WidgetKit
import FlatRadarCore

/// 桌面上那一格：**下一次什么时候有房，以及往后几周的形状**。
///
/// 为什么是日历而不是地图
/// --------------------
/// 两个都考虑过。日历赢在三件事上：
///
/// 1. **它是纯数字**，画出来不需要任何图片。地图那一格得先有一张瓦片图，而这个
///    扩展是**不联网**的（见 ``WidgetSnapshot`` 顶部），只能由 app 渲染成 PNG
///    写进共享容器——多一条图片管线、多一份缓存失效逻辑。
/// 2. **它每天都在变。** 地图上那些点几周才挪一次，而"下一个有货的日子"随时在
///    往前推。一格几天不变的小组件，读者很快就不看了。
/// 3. **它答得上一个具体问题**："我什么时候能搬进去"。一张 160pt 见方、上面撒着
///    几百个点的荷兰地图答不上任何问题——那个尺寸下，点会糊成一团。
///
/// 口径和日历那一屏（``CalendarPane``）完全一致
/// -----------------------------------------
/// 尤其是 `bookable` 这一层：实测 691 条里 609 条是 Occupied（88%），它们的
/// `available_from` 是未来的**退租日**，不是"现在能订"。所以柱子的总高是那天
/// 起租的全部，**实心的那一段**才是能动手的——一眼能看出"有很多，但能抢的没
/// 几套"。只给一个总数的话，"这天 237 条"会被读成"237 套可以抢"，差一个数量级。
struct CalendarWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.calendar, provider: SnapshotProvider()) { entry in
            CalendarFace(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Move-ins")
        .description("The next date with something you can actually book, and the weeks ahead.")
        // **不给 systemSmall**：这一格的价值在那排柱子上，而 128pt 宽塞不下
        // 14 根还看得出形状的柱子。只剩一个日期的话，它和状态那一格重复了。
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct CalendarFace: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View { CalendarLayout(entry: entry, family: family) }
}

struct CalendarLayout: View {

    let entry: SnapshotEntry
    let family: WidgetFamily

    /// 中号铺两周，大号铺四周。
    ///
    /// 都是 7 的倍数，所以柱子的疏密在两档之间是**同一个节奏**——不是"大号把
    /// 同样的东西放大"，而是"同样的粒度看得更远"。
    private var days: Int { family == .systemLarge ? 28 : 14 }

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    private var window: [MoveInDay] { Array(snapshot?.moveIns.prefix(days) ?? []) }
    private var isFresh: Bool { snapshot?.isFresh(at: entry.date) ?? false }
    /// 头条那天在这段窗口里的下标，用来在那根柱子底下打个记号。
    private var highlight: Int? {
        guard let next = MoveInDay.nextBookable(in: window) else { return nil }
        return window.firstIndex(of: next)
    }

    var body: some View {
        switch family {
        case .systemLarge:  large
        default:            medium
        }
    }

    /// 中号：左边说"下一次是什么时候"，右边是往后两周的形状。
    ///
    /// 第一版是竖着排的（头条在上、柱子在下），渲染出来柱子只分到 22pt——
    /// 155pt 的高度被两行头条、尺、脚注吃掉之后就剩那么多，一排 2pt 的短线
    /// 读不出任何形状。横过来之后柱子拿到整格的高度，而头条本来就只要一列。
    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                headline
                // 中号也给这两个合计：左栏本来空着 60pt，而这两个数正好回答
                // 柱子回答不了的那一半——柱子给形状，这里给量。
                Spacer(minLength: 8)
                totals
                Spacer(minLength: 8)
                Footnote(entry: entry)
            }
            .frame(width: 140, alignment: .topLeading)

            strip(barWidth: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 大号：头条在上，整幅宽的四周柱子，底下两个合计。
    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
            strip(barWidth: 10)
                .padding(.top, 12)
            Spacer(minLength: 10)
            // 没数据时整块不画。`Move-ins 0 / Bookable 0` 读起来是「往后四周
            // 一套都没有」——那是个结论，而这时候我们只是没拿到数据。
            // 渲染空状态那一版时正是这么显示的。
            if !window.isEmpty { totals }
            Spacer(minLength: 8)
            Footnote(entry: entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 柱子 + 底下那条一周一格的尺。
    @ViewBuilder
    private func strip(barWidth: CGFloat) -> some View {
        if window.isEmpty {
            Spacer(minLength: 0)
        } else {
            VStack(spacing: 6) {
                BarRow(values: window.map(\.total),
                       solid: window.map(\.bookable),
                       tick: highlight,
                       barWidth: barWidth)
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel(barAccessibility)
                weekRuler
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 头条

    /// 「下一个能抢的日子」。
    ///
    /// 找的是 `bookable > 0` 而不是 `total > 0`：后者的第一个命中多半是一堆
    /// Occupied 的退租日，点进去什么也做不了——那种"下一个"是假的。
    @ViewBuilder
    private var headline: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(StatusWording.nextMoveIn)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let snapshot, snapshot.showsUnread, snapshot.unreadAlerts > 0 {
                UnreadPill(count: snapshot.unreadAlerts)
            }
        }
        if let next = MoveInDay.nextBookable(in: window), let date = next.date {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(Self.dayFormatter.string(from: date))
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .foregroundStyle(isFresh ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(StatusWording.bookableCount(next.bookable))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 1)
        } else {
            // 三种"没有日期可说"，说的**不是**同一件事：
            //
            // - 连快照都没有 → `—`。和别处一样：拿不到就是拿不到，不编。
            //   底下那行脚注会说 `Open FlatRadar`，不必在这儿再说一遍。
            // - 有快照但日历数据是空的 → 那一格刚被摆上桌面，app 还没为它去拉
            //   `/calendar`（见 `AppFeed.fetchCalendarIfWidgetInstalled`）。
            //   这时候该说的是下一步动作。
            // - 数据齐全、就是往后几周一套能抢的都没有 → 那是个**结论**，直说。
            Text(headlineFallback)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.top, 1)
        }
    }

    private var headlineFallback: String {
        guard snapshot != nil else { return StatusWording.countText(nil) }
        return window.isEmpty ? StatusWording.openApp : StatusWording.noneBookable
    }

    // MARK: - 柱子底下那条尺

    /// 每隔七天一个标记。没有坐标轴（t2「去线留白」），但一排没有刻度的柱子
    /// 回答不了"那根高的是哪天"——一周一个标记是给出那个答案的最少笔墨。
    private var weekRuler: some View {
        HStack(spacing: 3) {
            ForEach(Array(window.enumerated()), id: \.offset) { index, day in
                Group {
                    if index % 7 == 0, let date = day.date {
                        Text(Self.rulerFormatter.string(from: date))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 11)
    }

    // MARK: - 大号底下的两个数

    private var totals: some View {
        VStack(alignment: .leading, spacing: 7) {
            MetricRow(title: StatusWording.moveIns,
                      value: window.reduce(0) { $0 + $1.total },
                      caption: StatusWording.spanDays(days), dimmed: !isFresh)
            MetricRow(title: StatusWording.bookable,
                      value: window.reduce(0) { $0 + $1.bookable }, dimmed: !isFresh)
        }
    }

    private var barAccessibility: String {
        let total = window.reduce(0) { $0 + $1.total }
        let bookable = window.reduce(0) { $0 + $1.bookable }
        return "\(total) move-ins over the next \(days) days, \(bookable) bookable"
    }

    /// `Oct 1`。用服务端时区——后端按 Europe/Amsterdam 分的桶，
    /// 用本地时区格式化会在月初差一天（记忆里那条「日期一律用 ServerTime」）。
    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = ServerTime.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    nonisolated private static let rulerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = ServerTime.timeZone
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()
}

// MARK: - 预览

#Preview("Medium", as: .systemMedium) {
    CalendarWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .sample)
}

#Preview("Large", as: .systemLarge) {
    CalendarWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .sample)
    SnapshotEntry(date: Date(), snapshot: nil)
}
