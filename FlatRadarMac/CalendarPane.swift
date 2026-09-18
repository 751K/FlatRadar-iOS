import SwiftUI
import FlatRadarCore

/// 日历屏：统计带 + 月份导航 + 月网格 + 状态栏。
///
/// 为什么是月网格，而不是 docs/DESIGN.md §7.4 猜的时间轴
/// --------------------------------------------------
/// §7.4 当时的顾虑是「月网格在 1400pt 里只占中间一条」，并提议改成按周分列的
/// 时间轴。设计稿最后仍然选了月网格，而且是对的——因为它的格子里装的是
/// **条目卡片**（圆点 + 价格 + 楼盘），不是一个计数数字。装得下内容，宽度就
/// 不浪费；一次只看一个月，稀疏也就不是问题。
///
/// 我一度按「135/3714 天有货 = 96% 的格子是空的」反对过网格，那个算法是错的：
/// 96% 是拿**整个 10 年跨度**算的，而网格一次只画一个月。放到 2026-09
/// （实测 237 条）格子是满的。
///
/// 设计稿里有三样东西这里**没有画**
/// ------------------------------
/// 都是因为后端没有那个数据，不是漏了：
///
/// - **Lottery deadlines**（"closes 17:00"）：openapi 里 `deadline` / `closes` /
///   `draw_at` 各出现 0 次，listings 表只有 `available_from` 一个日期列，
///   而且**只到日、没有时刻**。顶部那张琥珀色 "Next deadline" 英雄卡、格子里的
///   琥珀条、侧栏的 "Next up" 区全建立在它上面。
/// - **Viewings**（"Viewing 14:00"）：同上，而且这本身是「我预约了看房」，
///   属于用户数据，后端连这个概念都没有。
/// - **Subscribe (.ics) / Add to Calendar.app**：能做（EventKit + 导出），
///   但那要单独申请权限和 entitlement，是另一件事。
///
/// 按这个仓库一贯的规矩（``SidebarView`` 的「只显示真的有的数」、
/// ``InspectorPane/partialDetail(_:)`` 的「明说缺」），宁可不画，也不拿假数据
/// 把控件填满——一个永远填不上的 "Next deadline" 卡片比没有这张卡片更糟。
/// 三个位置换成了真有数据的东西，见 ``statsStrip``。
struct CalendarPane: View {

    @Bindable var model: BrowseModel
    let store: CalendarStore

    /// 当前翻到哪个月（该月 1 号）。
    @State private var anchor = CalendarGrid.startOfMonth(Date())
    /// 首次加载完自动落到「今天所在的月」只做一次，之后不再抢用户翻到的位置。
    @State private var didSettle = false

    var body: some View {
        VStack(spacing: 0) {
            statsStrip
                .padding(.horizontal, 18)
                .padding(.top, 12)
            monthBar
            Divider()
            grid
            Divider()
            statusBar
        }
        .onChange(of: store.listings.count) { _, count in
            guard !didSettle, count > 0 else { return }
            didSettle = true
            settleOnBestMonth()
        }
    }

    // MARK: - 派生

    /// 月网格、可订数、下一个入住日、排除统计——全部按输入缓存，见 ``CalendarDerived``。
    @State private var derived = CalendarDerived()

    /// 今天（服务端时区）。过了零点，"今天"那一格和"下一个入住日"要跟着变。
    private var today: Date { CalendarGrid.startOfDay(Date()) }

    private var month: CalendarDerived.MonthSummary {
        derived.month(anchor: anchor, store: store, today: today)
    }
    private var monthGrid: CalendarMonthGrid { month.grid }
    private var actionable: Int { month.actionable }

    private var window: (first: Date, last: Date) { CalendarGrid.window() }

    private var canGoBack: Bool { anchor > window.first }
    private var canGoForward: Bool { anchor < window.last }

    // MARK: - 统计带

    /// 三个位置对着设计稿，但内容换成有数据的：
    ///
    /// | 设计稿 | 这里 | 为什么 |
    /// |---|---|---|
    /// | Next deadline（琥珀英雄卡） | Next move-in | 没有 deadline 数据，但「下一个有货的日子」是真的 |
    /// | Move-ins / Deadlines / Viewings | Move-ins / Bookable / Turnover | 后两个不存在；换成能把 88% Occupied 这件事说清楚的拆分 |
    private var statsStrip: some View {
        HStack(alignment: .center, spacing: 26) {
            anchorMetric
            nextMoveInCard
            Spacer(minLength: 12)
            metrics
        }
        .padding(.horizontal, 18)
        .frame(height: 120)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private var anchorMetric: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Dated items this month")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(monthGrid.itemCount)")
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .tracking(-1.4)
                .monospacedDigit()
                .padding(.top, 2)
            // 单复数写成两个完整的 key，不在句尾拼 "s"：拼出来的 "s" 是个普通
            // String 参数，别的语言的译文要么带着它、要么只能丢参数。
            Text(monthGrid.buildingCount == 0 ? "no building names on these"
                 : monthGrid.buildingCount == 1 ? "across 1 building"
                 : "across \(monthGrid.buildingCount) buildings")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
    }

    /// 下一个有房源起租的日子。设计稿那张琥珀卡的位置。
    ///
    /// **不用琥珀色**：琥珀在这套设计里是 Lottery 的色（见 ``Theme``），
    /// 而这张卡说的不是抽签，也不是一个会过期的截止时间。用中性底。
    @ViewBuilder
    private var nextMoveInCard: some View {
        if let next = nextMoveIn {
            VStack(alignment: .leading, spacing: 3) {
                Text("Next move-in")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Self.longDate.string(from: next.date))
                    .font(.headline)
                Text(next.count == 1 ? "1 listing" : "\(next.count) listings")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    /// 从今天起，第一个有条目的日子。整个数据集里找，不限当前翻到的月份——
    /// 翻到一个空月份时它仍然要能指路。
    private var nextMoveIn: (date: Date, count: Int)? {
        derived.nextMoveIn(store: store, today: today)
    }

    private var metrics: some View {
        HStack(alignment: .top, spacing: 30) {
            metric("Move-ins", monthGrid.itemCount, "dated this month")
            metric("Bookable", actionable, "book or lottery")
            metric("Turnover", monthGrid.itemCount - actionable, "occupied until then")
        }
        .fixedSize()
    }

    private func metric(_ title: String, _ value: Int, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .padding(.top, 2)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
    }

    // MARK: - 月份导航

    private var monthBar: some View {
        HStack(spacing: 10) {
            stepButton("chevron.left", enabled: canGoBack) { step(-1) }
            stepButton("chevron.right", enabled: canGoForward) { step(1) }
            Text(monthGrid.title)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .padding(.leading, 4)
            Button("Today") { withAnimation(.easeOut(duration: 0.14)) { anchor = CalendarGrid.startOfMonth(Date()) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(CalendarGrid.startOfMonth(Date()) == anchor)
            Spacer(minLength: 0)
            if store.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func stepButton(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.callout.weight(.semibold)) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!enabled)
    }

    private func step(_ delta: Int) {
        guard let next = CalendarGrid.gridCalendar.date(byAdding: .month, value: delta, to: anchor)
        else { return }
        withAnimation(.easeOut(duration: 0.14)) { anchor = next }
    }

    /// 数据到齐后落到「今天所在的月」；今天在窗口外就夹回窗口边界。
    private func settleOnBestMonth() {
        let today = CalendarGrid.startOfMonth(Date())
        anchor = min(max(today, window.first), window.last)
    }

    // MARK: - 网格

    private var grid: some View {
        VStack(spacing: 0) {
            weekdayHeader
            GeometryReader { proxy in
                let rows = monthGrid.weeks.count
                // 行高按可用高度均分，不给固定值：5 行和 6 行的月份都要正好铺满，
                // 否则六周的月份底部会被切掉一行。
                let rowHeight = max(64, proxy.size.height / CGFloat(max(rows, 1)))
                VStack(spacing: 0) {
                    ForEach(monthGrid.weeks) { week in
                        HStack(spacing: 0) {
                            ForEach(week.days) { day in
                                dayCell(day).frame(height: rowHeight)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(Array(CalendarGrid.weekdaySymbols.enumerated()), id: \.offset) { index, symbol in
                Text(symbol)
                    .font(.subheadline)
                    // 周末更淡：设计稿的表头就是这么分的，扫的时候一眼看出周界。
                    .foregroundStyle(index >= 5 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - 一个格子

    /// 用 `Button` 而不是 `.onTapGesture`。
    ///
    /// 实测：窗口**不在前台**时，`.onTapGesture` 的第一下会被吞掉——AppKit 把
    /// 那一击当成"激活窗口"用了，不往下传。`Button` 走的是 AppKit 的按钮路径，
    /// 接得住 first mouse。右栏那些行（``InspectorPane/calendarRow(_:)``）一直
    /// 是 `Button`，所以它们没这个毛病，对比之下才看出来。
    ///
    /// 这不是测试环境的假象：用户从别的 app 切回来点日历的第一下，同样丢。
    /// 顺带还白拿了键盘可达和 VoiceOver 的按钮语义。
    private func dayCell(_ day: CalendarDay) -> some View {
        let selected = model.calendarDay == day
        return Button { select(day) } label: { cellBody(day, selected: selected) }
            .buttonStyle(.plain)
            // 空格子不该显示成可点——点了右栏也没东西可放。
            .disabled(day.count == 0)
            .accessibilityLabel(Self.longDate.string(from: day.date))
            .accessibilityValue(day.count == 0 ? "No listings" : "\(day.count) listings")
    }

    private func cellBody(_ day: CalendarDay, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                dayNumber(day)
                Spacer(minLength: 2)
                if day.count > 0 {
                    Text("\(day.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(day.items.prefix(Self.chipsPerCell)) { item in
                chip(item)
            }
            if day.count > Self.chipsPerCell {
                Text("+\(day.count - Self.chipsPerCell) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(CalendarCellSurface(selected: selected, hasContent: day.count > 0))
        .contentShape(Rectangle())
        // 邻月补的那几天压暗，但**不禁用**——它们有内容时照样点得开。
        .opacity(day.isInMonth ? 1 : 0.38)
    }

    private func dayNumber(_ day: CalendarDay) -> some View {
        Text("\(day.dayNumber)")
            .font(.callout.weight(day.isToday ? .bold : .medium))
            .monospacedDigit()
            .foregroundStyle(day.isToday ? AnyShapeStyle(Color.white)
                             : day.isWeekend ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .frame(width: 19, height: 19)
            .background {
                if day.isToday { Circle().fill(Theme.ink) }
            }
    }

    /// 格子里的一条。**圆点 + 价格 + 楼盘名**，和设计稿一致。
    ///
    /// 价格在前、名字在后：这一屏回答的是「这天有什么放出来」，价格是最先要
    /// 比的那个量；名字在这个字号下经常被截断，放前面就等于两边都读不到。
    private func chip(_ item: CalendarListing) -> some View {
        let kind = ListingStatus.from(item.status)
        return HStack(spacing: 4) {
            Circle()
                .fill(Theme.statusColor(kind))
                .frame(width: 5, height: 5)
            Text(PriceText.compact(item.priceRaw) ?? "—")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .fixedSize()
            Text(item.building.isEmpty ? item.name : item.building)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
    }

    private static let chipsPerCell = 3

    private func select(_ day: CalendarDay) {
        model.calendarDay = day
        // 顺手把右栏的详情焦点也挪过去：右栏上半是当天列表，下半是选中那条的
        // 详情，两截要对得上。
        model.focused = day.items.first.map(\.id)
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 6) {
            if let error = store.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            } else {
                // 不用 `+` 拼：拼出来是普通 String，不查字符串表。
                Text(monthGrid.itemCount == 1
                     ? "1 dated item in \(monthGrid.title) · \(actionable) bookable"
                     : "\(monthGrid.itemCount) dated items in \(monthGrid.title) · \(actionable) bookable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if excluded > 0 {
                // 明说排除了多少条，不闷掉——见 ``CalendarGrid/window(now:)``。
                Text("\(excluded) with out-of-range dates not shown")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .help("Some platforms publish placeholder dates years in the past or future. The calendar covers 12 months back to 24 months ahead.")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }

    private var excluded: Int {
        derived.excluded(store: store, thisMonth: CalendarGrid.startOfMonth(Date()))
    }

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.calendar = ServerTime.calendar
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE d MMMM"
        return f
    }()
}

/// 日历格子的底：选中走**液态玻璃**，其余按"这天有没有内容"给一层极淡的底。
///
/// 选中态直接复用 ``RowSurface``，和列表屏 / Alerts / 右栏那些小行是同一份配方。
///
/// 之前不是这样：这里自己 `fill` 了一层 `Theme.selectionFill` 再描一圈墨色边框，
/// 注释里给的理由是"格子这么小放不下液态玻璃那套"。那个理由**站不住**——格子实测
/// 130×113pt，比列表行还大得多。描边是在补救填充不够看：`#E7E7EA` 和「这天有内容」
/// 的 primary 4.5% 明度几乎一样，选中 7 号之后它和旁边同样有内容的 14 / 16 / 21
/// 看不出区别。玻璃本身就把格子抬起来了，那圈边随之作废——也就不用再为它破例
/// t2「去线留白」那条规则。
private struct CalendarCellSurface: ViewModifier {

    let selected: Bool
    let hasContent: Bool

    func body(content: Content) -> some View {
        Group {
            if selected {
                content.modifier(RowSurface(isSelected: true, isHovered: false))
            } else {
                content.background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(hasContent ? 0.045 : 0.018)))
            }
        }
        // 格子之间留一条 1.5pt 的缝，相邻两个格子的底不会连成一片。
        .padding(1.5)
    }
}
