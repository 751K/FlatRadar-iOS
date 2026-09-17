import SwiftUI
import WidgetKit
import FlatRadarCore

/// 桌面上第三格：**下一次什么时候有房，以及往后几周的形状**。
///
/// 设计稿里没有这一格——它是之前那轮「是不是还可以做地图 base 的？或者日历
/// base 的？」的答案。**排版跟着设计稿走**（暖纸底、等宽大写段标题、靠填充分组），
/// 这样三格摆在一起是一套东西，不是两套。
///
/// 为什么是日历不是地图
/// ------------------
/// 日历是纯数字，画出来不需要任何图片；而地图那一格得先有瓦片图，这个扩展
/// **不联网**（见 ``WidgetSnapshot`` 顶部），只能由 app 渲染成 PNG 写进共享容器——
/// 多一条图片管线、多一份缓存失效逻辑。日历每天都在变，地图上那些点几周才挪
/// 一次。而且日历答得上一个具体问题（"我什么时候能搬进去"），一张 160pt 见方、
/// 撒着几百个点的荷兰地图在那个尺寸下只会糊成一团。
///
/// 口径和日历那一屏（``CalendarPane``）完全一致，尤其 **bookable**：实测 691 条里
/// 609 条是 Occupied（88%），它们的 `available_from` 是未来的**退租日**，不是
/// "现在能订"。所以柱子的总高是那天起租的全部，**实心那一段**才是能动手的。
struct CalendarWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.calendar, provider: SnapshotProvider()) { entry in
            WidgetSurface { CalendarFace(entry: entry) }
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
    @Environment(\.palette) private var palette

    /// 中号铺两周，大号铺四周。都是 7 的倍数，所以柱子的疏密在两档之间是
    /// **同一个节奏**——不是"大号把同样的东西放大"，而是"同样的粒度看得更远"。
    private var days: Int { family == .systemLarge ? 28 : 14 }

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    private var window: [MoveInDay] { Array(snapshot?.moveIns.prefix(days) ?? []) }
    private var isFresh: Bool { snapshot?.isFresh(at: entry.date) ?? false }

    var body: some View {
        switch family {
        case .systemLarge:  large
        default:            medium
        }
    }

    /// 中号：左边说"下一次是什么时候"，右边是往后两周的形状。
    ///
    /// 第一版是竖着排的，渲染出来柱子只分到 22pt——155pt 的高度被两行头条、尺、
    /// 脚注吃掉之后就剩那么多，一排 2pt 的短线读不出任何形状。
    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                headline
                Spacer(minLength: 8)
                totals
                Spacer(minLength: 8)
                LiveFooter(entry: entry)
            }
            .frame(width: 140, alignment: .topLeading)
            strip
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
            strip.padding(.top, 12)
            Spacer(minLength: 10)
            // 没数据时整块不画。`Move-ins 0 / Bookable 0` 读起来是「往后四周
            // 一套都没有」——那是个结论，而这时候我们只是没拿到数据。
            if !window.isEmpty { totals }
            Spacer(minLength: 8)
            LiveFooter(entry: entry)
        }
    }

    // MARK: - 头条

    @ViewBuilder
    private var headline: some View {
        HStack(spacing: 6) {
            Dot(color: palette.lottery, size: 7)
            SectionLabel(text: StatusWording.nextMoveIn)
        }
        if let next = MoveInDay.nextBookable(in: window), let date = next.date {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(ServerTime.shortDate(date))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(isFresh ? palette.ink : palette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(StatusWording.bookableCount(next.bookable))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            .padding(.top, 3)
        } else {
            // 三种"没有日期可说"说的不是同一件事：连快照都没有 → `—`；有快照但
            // 日历数据空着 → 那一格刚摆上桌面，app 还没为它去拉 `/calendar`；
            // 数据齐全就是没得抢 → 那是个结论，直说。
            Text(fallback)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.muted)
                .lineLimit(2)
                .padding(.top, 3)
        }
    }

    private var fallback: String {
        guard snapshot != nil else { return StatusWording.countText(nil) }
        return window.isEmpty ? StatusWording.openApp : StatusWording.noneBookable
    }

    // MARK: - 柱子

    /// 柱子的总高是那天起租的全部，实心那段是能抢的；被点名那天底下打个记号。
    ///
    /// 记号而不是整根染色：这一格里**棕色已经有含义了**（能抢的），再拿它整根
    /// 染一遍，同一个颜色在同一张图里说两件事。
    @ViewBuilder
    private var strip: some View {
        if window.isEmpty {
            Spacer(minLength: 0)
        } else {
            let peak = max(window.map(\.total).max() ?? 0, 1)
            let markIndex = MoveInDay.nextBookable(in: window).flatMap { window.firstIndex(of: $0) }
            VStack(spacing: 6) {
                GeometryReader { proxy in
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(window.enumerated()), id: \.offset) { index, day in
                            bar(day, peak: peak, height: proxy.size.height, marked: index == markIndex)
                        }
                    }
                    .frame(height: proxy.size.height, alignment: .bottom)
                }
                ruler
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(barAccessibility)
        }
    }

    private func bar(_ day: MoveInDay, peak: Int, height: CGFloat, marked: Bool) -> some View {
        // 值大于 0 时至少 3pt——否则 22 里的 1 只有 2.5pt，和"这天没有"长得一样，
        // 而两者说的是相反的事。
        let scale = { (v: Int) in v <= 0 ? 0 : max(height * CGFloat(v) / CGFloat(peak), 3) }
        return VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(palette.barIdle)
                    .frame(height: max(scale(day.total), 2))
                if day.bookable > 0 {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isFresh ? palette.lottery : palette.barIdle)
                        .frame(height: scale(day.bookable))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            Capsule()
                .fill(marked ? palette.lottery : Color.clear)
                .frame(height: 2)
        }
        .frame(maxWidth: .infinity)
    }

    /// 每隔七天一个标记。没有坐标轴，但一排没有刻度的柱子回答不了"那根高的是
    /// 哪天"——一周一个标记是给出那个答案的最少笔墨。
    private var ruler: some View {
        HStack(spacing: 3) {
            ForEach(Array(window.enumerated()), id: \.offset) { index, day in
                Group {
                    if index % 7 == 0, let date = day.date {
                        Text(ServerTime.shortDate(date))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(palette.muted)
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

    // MARK: - 合计

    private var totals: some View {
        VStack(alignment: .leading, spacing: 5) {
            KindRow(symbol: AnyView(Dot(color: palette.barIdle)),
                    title: StatusWording.moveIns,
                    value: window.reduce(0) { $0 + $1.total })
            KindRow(symbol: AnyView(Dot(color: palette.lottery)),
                    title: StatusWording.bookable,
                    value: window.reduce(0) { $0 + $1.bookable })
            // 两档尺寸铺的天数不同，合计也就不同——不写清范围的话，
            // 同一个 `Move-ins` 在中号和大号上是 30 和 74。
            Text(StatusWording.spanDays(days))
                .font(.system(size: 9.5))
                .foregroundStyle(palette.muted)
                .padding(.leading, 7)
        }
    }

    private var barAccessibility: String {
        let total = window.reduce(0) { $0 + $1.total }
        let bookable = window.reduce(0) { $0 + $1.bookable }
        return "\(total) move-ins over the next \(days) days, \(bookable) bookable"
    }
}

#Preview("Medium", as: .systemMedium) {
    CalendarWidget()
} timeline: { SnapshotEntry(date: Date(), snapshot: .sample) }

#Preview("Large", as: .systemLarge) {
    CalendarWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .sample)
    SnapshotEntry(date: Date(), snapshot: nil)
}
