import SwiftUI
import WidgetKit
import FlatRadarCore

/// 桌面上那一格：**今天有什么新的**。
///
/// 照 `FlatRadar Widgets.dc.html` 4a（macOS · 通知中心一栏）做。设计稿那句总纲：
///
/// > 四个尺寸一套内容层级：**小号只回答一个问题**（今日新增多少 / 未读多少），
/// > **中号加最新三条**，**大号加 14 天趋势、三项统计与最近截止**。
///
/// 所以三档是同一个层级的三次截断，不是三种设计。
///
/// 两处和设计稿不一样，都是因为**那个数据不存在**
/// ------------------------------------------
/// 规矩是 `CalendarPane` 顶上写过的那条：「宁可不画，也不拿假数据把控件填满——
/// 一个永远填不上的卡片比没有这张卡片更糟」。
///
/// | 设计稿 | 这里 | 为什么 |
/// |---|---|---|
/// | 第三格统计 `Watching 12` | `Matching filters 193` | 没有"关注列表"这个概念。`BrowseModel.pinned` 是「钉两套并排比」，上限 2、而且是窗口级的，不是一个可以显示成 12 的东西 |
/// | 底部 `Lottery closes · … in 2d` | `Next move-in · 23 Sep · in 6d` | openapi 里 `deadline` / `closes` / `draw_at` **各出现 0 次**，listings 表只有 `available_from` 一个日期列而且只到日。抽签截止时刻整条不存在 |
///
/// 后者换的是内容不是形状：同一个棕色胶囊、同一个「圆点 + 一句话 + 右端一个
/// 相对时间」，只是里面放的是真有的那个日期。
struct StatusWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.status, provider: SnapshotProvider()) { entry in
            WidgetSurface { StatusFace(entry: entry) }
        }
        .configurationDisplayName("What's new")
        .description("New listings today, the newest three, and how the last two weeks went.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// 从环境里取尺寸档，其余交给 ``StatusLayout``。
///
/// 拆两层只为一件事：**能在小组件宿主之外把这几档画出来看**。
/// `EnvironmentValues.widgetFamily` 在 SDK 里是只读的（没有 setter），而
/// `previewContext(WidgetPreviewContext(family:))` 在 Xcode 预览之外不起作用——
/// 试过，脚本里无论传哪一档画出来的都是 medium 那一版。
struct StatusFace: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family
    var body: some View { StatusLayout(entry: entry, family: family) }
}

struct StatusLayout: View {

    let entry: SnapshotEntry
    let family: WidgetFamily
    @Environment(\.palette) private var palette

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    private var isFresh: Bool { snapshot?.isFresh(at: entry.date) ?? false }

    var body: some View {
        switch family {
        case .systemLarge:  large
        case .systemMedium: medium
        default:            small
        }
    }

    // MARK: - 小

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Diamond(color: palette.accent)
                SectionLabel(text: StatusWording.newToday)
                Spacer(minLength: 4)
                unreadPill
            }
            Spacer(minLength: 4)
            anchor(size: 46)
            // 小号有地方写全这句，中号只放得下 `avg 19 · 831 live`。
            if let base = baseline {
                Text(StatusWording.vsBaseline(base))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            Spacer(minLength: 4)
            bars(height: 26)
            LiveFooter(entry: entry).padding(.top, 9)
        }
    }

    // MARK: - 中

    private var medium: some View {
        HStack(alignment: .top, spacing: 15) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Diamond(color: palette.accent)
                    SectionLabel(text: StatusWording.newToday)
                }
                anchor(size: 40).padding(.top, 6)
                Text(compactBaseline)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .padding(.top, 3)
                Spacer(minLength: 6)
                bars(height: 34)
            }
            .frame(width: 120)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    SectionLabel(text: StatusWording.newest)
                    Spacer(minLength: 4)
                    unreadPill
                }
                .padding(.bottom, 7)
                newestRows(longSubtitle: false)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - 大

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("FlatRadar")
                    .font(.system(size: 12.5, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 4)
                LiveFooter(entry: entry, showsCount: false)
            }

            HStack(alignment: .lastTextBaseline, spacing: 9) {
                // 设计稿这里是 54pt。那张稿子的大号是 360×376，而 macOS 真正的
                // 大号是 **329×345**（HIG 的尺寸表）——矮了 31pt。整屏按同一个
                // 比例收了一档，而不是砍掉某一段内容：内容层级是设计稿的主张，
                // 尺寸是系统给的，该让的是后者。
                DisplayNumber(text: snapshot?.newTodayText ?? StatusWording.countText(nil),
                              size: 46, dimmed: !isFresh)
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel(text: StatusWording.newToday)
                    if let pct = snapshot?.changeVsBaseline, let base = baseline {
                        Text("\(StatusWording.percent(pct)) \(StatusWording.vsAverage(base))")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(pct >= 0 ? palette.up : palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 10)

            bars(height: 36, spacing: 4, radius: 2).padding(.top, 10)
            axis.padding(.top, 4)

            HStack(spacing: 6) {
                StatChip(title: StatusWording.liveNow,
                         value: snapshot?.totalListings, dimmed: !isFresh)
                if snapshot?.showsUnread ?? false {
                    StatChip(title: StatusWording.unread,
                             value: snapshot?.unreadAlerts, tinted: true, dimmed: !isFresh)
                }
                // 设计稿这一格是 `Watching 12`——没有那个数据，见类型注释。
                //
                // 套了个人筛选时放匹配数；**没套的时候放状态变更**。因为没套筛选
                // 时 `/listings` 的 total 就是全库 total，那一格会和左边的
                // `Live now` 显示同一个数——渲染访客那一版时一眼看到：
                // `Live now 831` / `Listings 831`，两格一模一样。
                if snapshot?.isFiltered ?? false {
                    StatChip(title: StatusWording.countLabel(isFiltered: true),
                             value: snapshot?.matchCount, dimmed: !isFresh)
                } else {
                    StatChip(title: StatusWording.statusChanges,
                             value: snapshot?.statusChanges, dimmed: !isFresh)
                }
            }
            .padding(.top, 10)

            SectionLabel(text: StatusWording.newest).padding(.top, 10).padding(.leading, 2)
            newestRows(longSubtitle: true).padding(.top, 5)

            Spacer(minLength: 8)
            nextMoveInChip
        }
    }

    // MARK: - 零件

    private var unreadPill: some View {
        Group {
            if let snapshot, snapshot.showsUnread, snapshot.unreadAlerts > 0 {
                UnreadPill(count: snapshot.unreadAlerts)
            }
        }
    }

    /// 大数字 + 涨跌。和统计带的锚点逐项一致。
    private func anchor(size: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 7) {
            DisplayNumber(text: snapshot?.newTodayText ?? StatusWording.countText(nil),
                          size: size, dimmed: !isFresh)
            if let pct = snapshot?.changeVsBaseline {
                Text(StatusWording.percent(pct))
                    .font(.system(size: size >= 46 ? 12 : 11.5, weight: .bold))
                    // 涨用绿、跌用次要色，**不用红**——房源变少不是错误，
                    // 红色会被读成告警。和统计带同一个判断。
                    .foregroundStyle(pct >= 0 ? palette.up : palette.muted)
            }
        }
    }

    private var baseline: Int? { snapshot.flatMap { DailyNew.baselineAverage($0.dailyNew) } }

    /// 中号左栏那一行：`avg 19 · 831 live`。窄，所以两句都缩写。
    private var compactBaseline: String {
        var parts: [String] = []
        if let base = baseline { parts.append(StatusWording.avgShort(base)) }
        if let live = snapshot?.totalListings { parts.append(StatusWording.liveCount(live)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func bars(height: CGFloat, spacing: CGFloat = 3, radius: CGFloat = 1.5) -> some View {
        if let series = snapshot?.dailyNew, series.count >= 3 {
            BarRow(values: series, spacing: spacing, radius: radius, dimmed: !isFresh)
                .frame(height: height)
                .accessibilityLabel("New listings over the last \(series.count) days")
        } else {
            Color.clear.frame(height: height)
        }
    }

    /// 柱子底下那两个端点标签。
    ///
    /// 起点是算出来的：`daily_new?days=14` 回的是**到今天为止连续 14 天**，
    /// 所以第一根柱子就是「今天往前数 count-1 天」。用 ``ServerTime/calendar``
    /// 推，不用 `Calendar.current`——后端按 Europe/Amsterdam 分的桶。
    @ViewBuilder
    private var axis: some View {
        if let count = snapshot?.dailyNew.count, count >= 3,
           let first = ServerTime.calendar.date(byAdding: .day, value: -(count - 1),
                                                to: entry.date) {
            HStack {
                Text(ServerTime.shortDate(first))
                Spacer(minLength: 4)
                Text(StatusWording.today)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(palette.muted)
        }
    }

    @ViewBuilder
    private func newestRows(longSubtitle: Bool) -> some View {
        let rows = snapshot?.newest ?? []
        if rows.isEmpty {
            // 一条都没有时不画空槽。设计稿那三行是有内容才成立的。
            EmptyView()
        } else {
            VStack(spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, listing in
                    ListingRow(listing: listing, index: index, now: entry.date,
                               longSubtitle: longSubtitle)
                }
            }
        }
    }

    /// 底部那条棕色胶囊。设计稿放的是抽签截止，这里放下一个能抢的日子——
    /// 理由见类型注释。没有日历数据时整条不画，而不是画一条空的。
    @ViewBuilder
    private var nextMoveInChip: some View {
        if let next = snapshot?.nextBookable, let date = next.date {
            HStack(spacing: 8) {
                Dot(color: palette.lottery, size: 7)
                Text(StatusWording.nextMoveInOn(ServerTime.shortDate(date)))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(StatusWording.inDays(daysUntil(date)))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(palette.ink)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(palette.lottery.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func daysUntil(_ date: Date) -> Int {
        let cal = ServerTime.calendar
        return cal.dateComponents([.day], from: cal.startOfDay(for: entry.date),
                                  to: cal.startOfDay(for: date)).day ?? 0
    }
}

// MARK: - 预览

#Preview("Small", as: .systemSmall) {
    StatusWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .sample)
    SnapshotEntry(date: Date(), snapshot: nil)
}

#Preview("Medium", as: .systemMedium) {
    StatusWidget()
} timeline: { SnapshotEntry(date: Date(), snapshot: .sample) }

#Preview("Large", as: .systemLarge) {
    StatusWidget()
} timeline: { SnapshotEntry(date: Date(), snapshot: .sample) }
