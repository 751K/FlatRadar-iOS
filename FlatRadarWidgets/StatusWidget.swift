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

    /// 锁屏那三种只有 iOS 有（设计稿 4c）。macOS 的通知中心没有对应的形态。
    static var families: [WidgetFamily] {
        #if os(iOS)
        [.systemSmall, .systemMedium, .systemLarge,
         .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.status, provider: SnapshotProvider()) { entry in
            WidgetSurface { StatusFace(entry: entry) }
        }
        .configurationDisplayName("What's new")
        .description("New listings today, the newest three, and how the last two weeks went.")
        .supportedFamilies(Self.families)
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
    @Environment(\.skin) private var skin

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    private var isFresh: Bool { snapshot?.isFresh(at: entry.date) ?? false }

    var body: some View {
        switch family {
        case .systemLarge:  large
        case .systemMedium: medium
        #if os(iOS)
        // 锁屏那三种由系统染色，走另一套画法（``AccessoryFaces``），
        // 不读色板——理由见那个文件顶部。
        case .accessoryCircular:    AccessoryFaces.Circular(entry: entry)
        case .accessoryRectangular: AccessoryFaces.Rectangular(entry: entry)
        case .accessoryInline:      AccessoryFaces.Inline(entry: entry)
        #endif
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
            if skin == .phone {
            // 4b 的小号：`avg 19 · 831 live` 贴在数字底下，末尾**没有**那行
            // 带绿点的脚注——整格到柱子为止。
            anchor(size: 48)
            Text(compactBaseline(at: entry.date))
                .font(.system(size: 11))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
                .padding(.top, 4)
            Spacer(minLength: 4)
            bars(height: 28)
            } else {
            anchor(size: 46)
            // 4a 的小号写得全，因为它底下那行是脚注不是这句。
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
    }

    // MARK: - 中

    private var medium: some View {
        HStack(alignment: .top, spacing: 15) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Diamond(color: palette.accent)
                    // 4b 中号把标题缩成 `TODAY`，4a 是 `NEW TODAY`。
                    // 两张稿子都出自同一份内容层级，这一处是稿子上的原话。
                    SectionLabel(text: mediumTitle)
                }
                anchor(size: mediumAnchor).padding(.top, 6)
                Text(compactBaseline(at: entry.date))
                    .font(.system(size: 10))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .padding(.top, 3)
                Spacer(minLength: 6)
                bars(height: mediumBars)
            }
            .frame(width: mediumColumn)

            VStack(alignment: .leading, spacing: 0) {
                // 中号同理：没有房源就不画那个段标题。这一档的右半边整个就是
                // 那一段，标题孤零零挂着更明显。
                if !(snapshot?.newest.isEmpty ?? true) {
                    HStack(spacing: 6) {
                        SectionLabel(text: StatusWording.newest)
                        Spacer(minLength: 4)
                        unreadPill
                    }
                    .padding(.bottom, 7)
                    newestRows(longSubtitle: false, limit: 3)
                }
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
                // 设计稿两张都是 54/56pt。**iOS 用得起，macOS 用不起**：
                // iOS 的 systemLarge 是 364×382，而 macOS 的是 329×345
                // （两张 HIG 尺寸表），矮了 37pt。所以 Mac 那档整屏收了一档，
                // 而不是砍掉某一段内容——内容层级是设计稿的主张，尺寸是系统给的。
                DisplayNumber(text: snapshot?.newTodayText ?? StatusWording.countText(nil),
                              size: largeAnchor, dimmed: !isFresh)
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
                // 4b 大号把未读做成数字右边一个红胶囊，而不是三格统计里的一格。
                if skin == .phone, let snapshot,
                   snapshot.showsUnread, snapshot.unreadAlerts > 0 {
                    UnreadPill(count: snapshot.unreadAlerts, label: StatusWording.unreadLower)
                }
            }
            .padding(.top, 12)

            bars(height: largeBars, spacing: 4, radius: 2).padding(.top, 12)
            axis.padding(.top, 4)

            // `Group` 包一层：`.padding` 挂不到裸的 if/else 上
            // （"reference to member 'padding' cannot be resolved without a
            // contextual type"）。
            Group {
            if skin == .phone {
                // 手机那一档：**三格统计收成一行字**。
                //
                // 三个填充块在 364pt 宽里各占 110pt，里面装的是「一个标题 + 一个
                // 数」——信息密度很低，而它吃掉的 40pt 高度正是下面那三条房源最
                // 缺的。收成一行之后，那三条的行高从 33 长到 44、标题 11.5→13、
                // 副标题 9.5→11，手机是拿在手里看的，地址和价钱才是要读的东西。
                summaryLine
            } else {
                HStack(spacing: 6) {
                    StatChip(title: StatusWording.liveNow,
                             value: snapshot?.totalListings, dimmed: !isFresh)
                    if snapshot?.showsUnread ?? false {
                        StatChip(title: StatusWording.unread,
                                 value: snapshot?.unreadAlerts, tinted: true, dimmed: !isFresh)
                    }
                    // 设计稿这一格是 `Watching 12`——没有那个数据，见类型注释。
                    //
                    // 套了个人筛选时放匹配数；**没套的时候放状态变更**。因为没套
                    // 筛选时 `/listings` 的 total 就是全库 total，那一格会和左边的
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
            }
            }
            .padding(.top, 12)

            // 一条房源都没有时**连标题一起不画**。渲染空态那一版时看到的是一个
            // 孤零零的 `NEWEST` 底下什么都没有——那读起来像加载失败，
            // 而实际是还没有数据。
            if !(snapshot?.newest.isEmpty ?? true) {
                SectionLabel(text: StatusWording.newest).padding(.top, 12).padding(.leading, 2)
                newestRows(longSubtitle: true, limit: largeRows, roomy: skin == .phone)
                    .padding(.top, 6)
            }

            Spacer(minLength: 8)
            // 4a 把「下一个能抢的日子」放在整格底部一条棕胶囊里；
            // 4b 那一端没有这条（它那三格里已经有第三个数了）。
            if skin == .mac { nextMoveInBar }
        }
    }

    // MARK: - 两端差在哪
    //
    // 差别全在这儿，别处只引用这些常量。两张稿子（4a macOS / 4b iOS）画的是同一套
    // 内容层级，尺寸不同是因为**系统给的画布不同**：
    //
    // |  | systemSmall | systemMedium | systemLarge |
    // |---|---|---|---|
    // | macOS | 155×155 | 329×155 | 329×**345** |
    // | iOS   | 170×170 | 364×170 | 364×**382** |
    //
    // 大号差 37pt，所以 Mac 那档只排得下两条房源、数字也小一档；iOS 排得下三条。

    private var mediumTitle: String { skin == .phone ? StatusWording.today : StatusWording.newToday }
    private var mediumAnchor: CGFloat { skin == .phone ? 42 : 40 }
    private var mediumBars: CGFloat { skin == .phone ? 32 : 34 }
    private var mediumColumn: CGFloat { skin == .phone ? 118 : 120 }
    private var largeAnchor: CGFloat { skin == .phone ? 56 : 50 }
    private var largeBars: CGFloat { skin == .phone ? 54 : 42 }
    private var largeRows: Int { skin == .phone ? 3 : 2 }

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

    /// `avg 19 · 831 live`。中号左栏和 iOS 小号都用它——窄，所以两句都缩写。
    ///
    /// **过期时整句换成 `Checked 3h ago`。** iOS 的小号按设计稿没有那行带绿点的
    /// 脚注，这一行就是那一格唯一说得出"这是什么时候的数"的地方；照直说
    /// `831 live` 等于替后端打包票。理由和 ``WidgetSnapshot/compactFooter(at:)``
    /// 是同一条。
    private func compactBaseline(at now: Date) -> String {
        guard let snapshot, snapshot.isFresh(at: now) else {
            return StatusWording.sentence(
                entry.snapshot.map { StatusWording.checked(
                    ServerTime.relativeTime(since: $0.capturedAt, now: now)) }
                ?? StatusWording.openApp)
        }
        var parts: [String] = []
        if let base = baseline { parts.append(StatusWording.avgShort(base)) }
        if let live = snapshot.totalListings { parts.append(StatusWording.liveCount(live)) }
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

    /// NEWEST 那一段。
    ///
    /// **大号只放两条，中号放三条**——看起来反了，但不是：
    ///
    /// 中号整个右半边就是这一段，三条把它填满，那一格说的就是"最近发生了什么"。
    /// 大号要在同一块高度里排下页眉、大数字、14 天柱子、三格统计、这一段、
    /// 底部那条胶囊——**六段东西**，而 macOS 的大号只有 345pt，比设计稿那张
    /// 360×376 矮 31pt。三条塞得进去，但整屏每一段都只能贴着彼此，
    /// 挤得没有呼吸。少一条房源换来的 36pt 全部还给了间距和三处尺寸
    /// （大数字 46→50、柱高 36→42、段间距 10→12、行高 30→33）。
    ///
    /// 少的是**同一种**信息的第三条，不是少一类信息；而大号比中号多的是
    /// 柱子、统计和下一个可入住日——它给的仍然更多，只是不在这一段上。
    @ViewBuilder
    private func newestRows(longSubtitle: Bool, limit: Int, roomy: Bool = false) -> some View {
        let rows = Array((snapshot?.newest ?? []).prefix(limit))
        if rows.isEmpty {
            // 一条都没有时不画空槽。设计稿那三行是有内容才成立的。
            EmptyView()
        } else {
            VStack(spacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, listing in
                    ListingRow(listing: listing, index: index, now: entry.date,
                               longSubtitle: longSubtitle, roomy: roomy)
                }
            }
        }
    }

    /// 手机大号那一行汇总。
    ///
    /// 要的形状是「几段事实用 `·` 串成一行」。原话给的例子是
    /// `831 live · 12 watching · 1 lottery closes in 2d`，后两段**都没有数据源**，
    /// 这是同一个缺口第三次撞上来：
    ///
    /// | 想要的 | 为什么没有 |
    /// |---|---|
    /// | `12 watching` | 没有"关注列表"这个概念。Mac 那边 `BrowseModel.pinned` 是「钉两套并排比」，上限 2、窗口级；iOS 连这个都没有 |
    /// | `1 lottery closes in 2d` | 抽签截止时刻在 openapi 里（`deadline` / `closes` / `draw_at`）**各出现 0 次**，listings 表只有 `available_from`，而且只到日 |
    ///
    /// 换成同样形状、真有数的三段：全库多少、我匹配多少、这一周来了多少。
    /// 规矩还是 `CalendarPane` 顶上那条——宁可不画，也不拿假数据把控件填满。
    ///
    /// **拿不到的那一段整段不出现**，不写 `— live`：一行里出现一个破折号，
    /// 读的人得先判断那是"没取到"还是"真的是零"。
    @ViewBuilder
    private var summaryLine: some View {
        if let text = StatusWording.summaryLine([
            snapshot?.totalListings.map(StatusWording.liveCount),
            // 没套个人筛选时不说这一段：那时它和 `831 live` 是同一个数。
            (snapshot?.isFiltered ?? false)
                ? snapshot?.matchCount.map(StatusWording.matchingCount) : nil,
            snapshot?.newThisWeek.map(StatusWording.weekCount),
        ]) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(isFresh ? palette.ink : palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// macOS 大号底部那条棕色胶囊。设计稿放的是抽签截止，这里放下一个能抢的
    /// 日子——理由见类型注释。没有日历数据时整条不画，而不是画一条空的。
    @ViewBuilder
    private var nextMoveInBar: some View {
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
