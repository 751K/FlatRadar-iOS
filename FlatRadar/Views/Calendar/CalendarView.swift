import SwiftUI

/// 入住日历视图。
///
/// 布局
/// ----
/// 1. 顶部月份切换条（← 当前月 → / 跳到今天）
/// 2. 7 列 weekday 表头（Mon..Sun，使用 ``Calendar.current`` 的 firstWeekday）
/// 3. 月格：每天显示数字 + 该日可入住数（小气泡 badge）
///    - 今天高亮蓝边
///    - 选中日填充蓝色背景
///    - 该日 0 套 → 数字灰
/// 4. 选中日的房源列表（点单条进 ListingDetailView via deep link）
///
/// 与 Map 共享一个交互模式：点元素弹底层 sheet，从 sheet 进详情走
/// ``NavigationCoordinator.openListing`` 复用 Listings tab 的 NavigationStack。
struct CalendarView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(NavigationCoordinator.self) private var coord
    @Environment(\.horizontalSizeClass) private var hSizeClass

    /// 宽屏（iPad）把日历下方的房源行**留白**放大一档。
    ///
    /// 只动间距，不动字号。曾经连字号一起放大（subheadline → title3 那一类），
    /// 查 HIG 之后撤了：iOS 和 iPadOS 共用同一套字阶（默认 17pt / 最小 11pt 是
    /// 同一行），按设备加一档会和 Dynamic Type 打架——想要更大的字是用户在系统
    /// 设置里表达的。
    ///
    /// 留白不属于字阶，加大是安全的，也确实是这一行在 iPad 上显得扁的原因之一。
    /// 但要认清它治不了根：那一屏真正的问题是日历占上面 40%、下面空着大半，
    /// 属于布局结构，不是行高。
    private var isRegular: Bool { hSizeClass == .regular }

    @State private var anchor: Date = Self.startOfMonth(for: Date())
    @State private var selectedDay: Date?
    @State private var showRefreshError = false
    /// 月份切换方向：-1 向前翻 / 1 向后翻 / 0 初始。
    /// 驱动 daysGrid 的 asymmetric transition 实现空间连续感。
    /// 跟手翻页时这条三联带子的额外横向偏移。0 = 当前月正好落在可视区。
    @State private var dragOffset: CGFloat = 0
    /// 一个月格子的宽度。箭头按钮翻页要用它算动画起点，而它只在 GeometryReader
    /// 里量得到，所以存一份出来。
    @State private var gridWidth: CGFloat = 0

    /// 上 / 当 / 下三个月的**预计算**格子。见 `daysGrid` 的注释：拖动时一格都
    /// 不重算，全靠这份缓存。
    @State private var monthCells: [[DayCell]] = []

    /// 本次拖动是不是横向的。**手势开始时判一次就锁定**，nil = 还没判。
    @State private var dragIsHorizontal: Bool?

    /// 正在横向拖动（含松手后的落定动画）。为真时月历只画日期数字。
    @State private var isSwiping = false

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = ServerTime.timeZone
        return c
    }()

    /// 月份标题 "May 2026"
    private static let monthTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    /// 完整日期 "Wednesday, May 14, 2026"
    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateStyle = .full
        return f
    }()

    /// 视图实测尺寸，用来判断横竖屏。
    @State private var size: CGSize = .zero

    /// 横屏时把月历和当日房源左右分栏。
    ///
    /// 竖排版本在竖屏下是对的，横屏下就不是：月历本身高度固定（约 350pt），
    /// 横屏可用高度只有 393（iPhone）到 834（iPad），月历吃掉上半屏之后，
    /// 当日房源那一列挤在下面一条缝里，而左右两侧大片空着。
    ///
    /// 判据是**朝向**（宽 > 高）而不是绝对宽度：横屏下稀缺的是纵向空间，这跟
    /// 屏幕多大无关，iPhone 横屏和 iPad 横屏是同一个问题。再加一个 700pt 的
    /// 下限，保证分栏后每列还有 ~350pt 可用——iPad Split View 拖到一半时
    /// （~570pt）分栏只会两边都挤。
    private var isSideBySide: Bool { size.width >= 700 && size.width > size.height }


    /// 分栏时月历占的宽度比例——月历 : 房源 = 2 : 3。
    ///
    /// 月历那边是七列固定网格，宽度给多了只是把日期数字之间的空白拉开；房源那边
    /// 是文字卡片，宽度直接换成每行能读到多少内容。所以该偏向房源。
    ///
    /// 一开始给的是 3:2，偏向月历——理由是它是导航控件，点它才有右边。但月历
    /// 拿到 500pt 以上的宽度并不会更好用：``UICalendarView`` 里那个月网格有**自己
    /// 的最大宽度**，容器再宽，多出来的部分只会被分页滚动视图拿去露出相邻月份的
    /// 日期（左右各几列灰数字）。所以宽度对月历是有上限收益的，对房源列不是。
    ///
    /// 一路收到过 1:2，那一档 iPhone 横屏只剩 ~250pt 画七列，偏挤。2:3 是回补
    /// 的一档：iPhone 横屏 ~310pt（接近 iPhone 竖屏原本的月历宽度），iPad 横屏
    /// 450–515pt。
    private static let calendarWidthRatio: CGFloat = 2.0 / 5.0

    var body: some View {
        // 不再自带 NavigationStack；外层 BrowseView 提供。
        Group {
            if store.isLoading && store.listings.isEmpty {
                ScrollView { ProgressView().padding(.top, 80) }
            } else if let err = store.errorMessage, store.listings.isEmpty {
                ScrollView { loadFailed(err) }
            } else if isSideBySide {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        calendarCard.padding(.vertical)
                    }
                    .frame(width: size.width * Self.calendarWidthRatio)

                    Divider()

                    ScrollView {
                        dayPane.padding(.vertical)
                    }
                    .refreshable { await store.refresh(); rebuildMonthCells() }
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        calendarCard
                        dayPane
                    }
                    .padding(.vertical)
                }
                .refreshable { await store.refresh(); rebuildMonthCells() }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .task { rebuildMonthCells() }
        .onChange(of: anchor) { _, _ in rebuildMonthCells() }
        // 数据变了要重算格子上的房源数。用 count 当指纹：真正的 listings 数组
        // 比较代价太高，而"条数没变但分布变了"只会在一次刷新恰好返回同样条数时
        // 出现——下面 refreshable 里刷完再算一次兜住这种情况。
        .onChange(of: store.listings.count) { _, _ in rebuildMonthCells() }
        .refreshable { await store.refresh(); rebuildMonthCells() }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    anchor = Self.startOfMonth(for: Date())
                    selectedDay = Date()
                } label: {
                    Text("Today").font(.subheadline.weight(.medium))
                }
                .disabled(Self.cal.isDate(anchor, equalTo: Self.startOfMonth(for: Date()),
                                          toGranularity: .month))
            }
        }
        .task {
            if store.listings.isEmpty {
                await store.fetch()
            }
        }
        .onChange(of: store.errorMessage) { _, new in
            showRefreshError = new != nil && !store.listings.isEmpty
        }
        .alert(
            store.lastError?.errorDescription ?? "Refresh Failed",
            isPresented: $showRefreshError
        ) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    // MARK: - Header

    /// 月份标题 / 星期行 / 日期格合成的那张卡。
    ///
    /// 原先三者各自平铺在页面上，没有边界，读起来是一堆散元素而不是「一个月历」。
    /// 大面板用实体表面而不是玻璃——玻璃在大面积上会把自己的内容也搅浑
    /// （地图那张说明卡踩过）。
    private var calendarCard: some View {
        // UICalendarView 自带月份标题和前后箭头，所以它替换的是原来的
        // monthHeader + weekdayHeader + daysGrid 三块。
        NativeMonthCalendar(
            selectedDay: $selectedDay,
            visibleMonth: $anchor,
            availableRange: store.dateRange,
            countForDay: { store.listings(on: $0).count }
        )
        // 宽度上限由 NativeMonthCalendar.sizeThatFits 自己卡（它会问视图愿意多宽），
        // 这里不再写死一个数——写死过 420（太窄）和 640（会露出相邻月份）。
        .padding(.vertical, 8)
        // 卡片底**贴着日历本身**，不是撑满整列。顺序反过来的话（先撑满再画底）
        // 卡片会横跨整个左栏，而里面的日历只占中间 420pt，两边各空一截。
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity)   // 画完底再在列里居中
        .padding(.horizontal, 16)
    }

    /// 左右滑切换月份——**跟手**。
    ///
    /// `onChanged` 把手指位移原样写进 `dragOffset`，带子 1:1 跟着走；`onEnded`
    /// 才决定去留：过了四分之一屏就翻页，否则弹回。
    ///
    /// 方向**在手势开始时判一次就锁定**，不在每帧重判。第一版写成每帧
    /// `guard abs(dx) > abs(dy)`，手指稍微斜一点那一帧就被丢掉，表现是一顿一顿的
    /// 阻滞感——而 CPU 占用并不高，因为问题不在算得慢，在于**该动的帧没动**。
    ///
    /// `minimumDistance` 从 12 压到 4：这段距离里内容纹丝不动，给大了就是一段
    /// "推不动"的死区。判方向的阈值 6pt——够区分意图，又不至于让人察觉到停顿。
    ///
    /// 用 `simultaneousGesture` 而不是 `gesture`：竖屏下这张卡在一个纵向
    /// ScrollView 里，独占手势会把上下滚动一起吃掉。锁轴之后两者不再互相干扰——
    /// 判成纵向的那一次我们完全不参与。
    ///
    /// 到边界时给阻尼而不是硬停，但**只打五折不是三折**：三折下手指划过一屏、
    /// 内容才动三分之一，那不像"到头了"，像卡住了。
    ///
    /// VoiceOver 用户看不到手势，但月份标题两侧的箭头按钮一直在，它们才是无障碍
    /// 路径——所以这个手势是加速器，不是唯一入口。
    private func monthSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if dragIsHorizontal == nil {
                    guard max(abs(dx), abs(dy)) > 6 else { return }
                    dragIsHorizontal = abs(dx) > abs(dy)
                    if dragIsHorizontal == true { isSwiping = true }
                }
                guard dragIsHorizontal == true else { return }
                let delta = dx < 0 ? 1 : -1
                dragOffset = canShiftMonth(delta) ? dx : dx * 0.5
            }
            .onEnded { value in
                defer { dragIsHorizontal = nil }
                guard dragIsHorizontal == true else { isSwiping = false; return }
                let dx = value.translation.width
                let vx = value.velocity.width
                let delta = dx < 0 ? 1 : -1

                // 位移**或**速度够就翻页。只看位移的话，一次短促的快扫会被判成
                // "不够"然后弹回去——手上的感觉就是"推不动"，而那正是最自然的
                // 翻页动作。速度阈值 350 pt/s 大约是随手一拨的下限。
                //
                // 速度方向必须和位移一致：往左拖到一半又往回甩，那是"我不要了"。
                let flicked = abs(vx) > 350 && (vx < 0) == (dx < 0)
                if (abs(dx) > width * 0.25 || flicked), canShiftMonth(delta) {
                    shiftMonth(delta, velocity: vx, width: width)
                } else {
                    // 落定动画期间同样保持简化态——那一段仍然在动，装饰照样是糊的。
                    withAnimation(Self.settle(distance: abs(dx), velocity: vx, width: width)) {
                        dragOffset = 0
                    } completion: {
                        withAnimation(.easeOut(duration: 0.16)) { isSwiping = false }
                    }
                }
            }
    }


    /// 右栏（横屏）／下半部分（竖屏）：选中那天的房源，或者一句提示。
    @ViewBuilder
    private var dayPane: some View {
        if let day = selectedDay {
            dayListings(for: day)
                .padding(.horizontal)
        } else if store.listings.isEmpty {
            ContentUnavailableView(
                "No Move-In Dates",
                systemImage: "calendar",
                description: Text("Listings with available dates will appear here."))
            .padding(.top, 40)
        } else {
            Text("Tap a day to view available listings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
        }
    }

    private func loadFailed(_ err: String) -> some View {
        let apiErr = store.lastError
        return ContentUnavailableView {
            Label(apiErr?.errorDescription ?? "Unable to Load",
                  systemImage: apiErr?.systemImage ?? "calendar.badge.exclamationmark")
        } description: {
            Text(err)
        } actions: {
            Button("Try Again") { Task { await store.refresh() } }
        }
    }

    private var monthHeader: some View {
        HStack(spacing: 8) {
            Button { shiftMonth(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .liquidGlass(Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .disabled(!canShiftMonth(-1))
            // icon-only：补 VoiceOver / Voice Control 用的语义化标签
            .accessibilityLabel("Previous month")

            Text(monthTitle(for: anchor))
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity)
                // 月份标题作为一个完整 a11y 元素朗读，避免 VO 把它和左右按钮
                // 错位关联
                .accessibilityAddTraits(.isHeader)

            Button { shiftMonth(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .liquidGlass(Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .disabled(!canShiftMonth(1))
            .accessibilityLabel("Next month")
        }
        .padding(.horizontal)
    }

    private var weekdayHeader: some View {
        let names = orderedWeekdaySymbols()
        return LazyVGrid(columns: Self.gridColumns, spacing: 4) {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Grid

    private static let gridColumns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 4),
        count: 7)

    /// 日期格：上 / 当 / 下三个月并排的一条带子，横向偏移。
    ///
    /// 原来是「换 `.id(anchor)` 触发 `.transition` 滑入滑出」。那种做法翻页动画
    /// 是**放出来的**——手指抬起之后才开始，中途松手也只能整段播完。跟手要的是
    /// 相反的东西：位移由手指决定，松手才决定去留。所以三个月一起渲染，拖动只是
    /// 改这条带子的 offset。
    ///
    /// 代价是每帧多渲染两个月的格子。可接受：一个月 42 格纯文本，而且
    /// `store.listings(on:)` 那层查询本来就是按日期索引的。
    /// 日期格：上 / 当 / 下三个月并排的一条带子，横向偏移。
    ///
    /// 原来是「换 `.id(anchor)` 触发 `.transition` 滑入滑出」。那种动画是**放出来
    /// 的**——手指抬起之后才开始，中途松手也只能整段播完。跟手要的是相反的东西：
    /// 位移由手指决定，松手才决定去留。所以三个月一起渲染，拖动只改这条带子的
    /// offset。
    ///
    /// **格子内容全部预计算**（`monthCells`），拖动时一格都不重算。第一版没这么做，
    /// 结果是每帧要跑 126 次 `store.listings(on:)`——那个函数内部走 `DateFormatter`
    /// 拼 key——外加 126 次 `isDateInToday` 和 `component(.day,)`。三个月 42 格
    /// 乘以每秒 120 帧，手感是明显的顿挫。
    private var daysGrid: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            HStack(spacing: 0) {
                ForEach(Array(monthCells.enumerated()), id: \.offset) { _, cells in
                    MonthGrid(cells: cells,
                              selectedDay: selectedDay,
                              cellHeight: cellHeight,
                              width: w,
                              detailed: !isSwiping,
                              onSelect: { selectedDay = $0 })
                        // 让 SwiftUI 在输入没变时整块跳过重绘。拖动只改父视图的
                        // dragOffset，三张月历的输入一个都没动。
                        .equatable()
                }
            }
            .frame(width: w * 3, alignment: .leading)
            .offset(x: -w + dragOffset)
            .contentShape(Rectangle())
            .simultaneousGesture(monthSwipe(width: w))
            .onAppear { gridWidth = w }
            .onChange(of: w) { _, new in gridWidth = new }
        }
        .frame(height: gridHeight)
        .clipped()
    }

    private func month(offsetFromAnchor delta: Int) -> Date {
        Self.cal.date(byAdding: .month, value: delta, to: anchor).map(Self.startOfMonth) ?? anchor
    }

    /// 重算上/当/下三个月的格子。只在月份或数据变化时调，不在拖动时调。
    private func rebuildMonthCells() {
        monthCells = (-1...1).map { dayCells(for: month(offsetFromAnchor: $0)) }
    }

    /// 把一个月摊成 42 格，**顺便把每格要显示的东西一次算完**。
    private func dayCells(for month: Date) -> [DayCell] {
        func blank(_ i: Int) -> DayCell {
            DayCell(id: i, date: nil, day: 0, count: 0, isToday: false)
        }
        guard let range = Self.cal.range(of: .day, in: .month, for: month) else {
            return (0..<(Self.rowsPerMonth * 7)).map(blank)
        }
        let firstWeekday = Self.cal.component(.weekday, from: month)
        let leading = (firstWeekday - Self.cal.firstWeekday + 7) % 7

        var out: [DayCell] = (0..<leading).map(blank)
        for d in range {
            guard let date = Self.cal.date(byAdding: .day, value: d - 1, to: month) else { continue }
            out.append(DayCell(id: out.count,
                               date: date,
                               day: d,
                               count: store.listings(on: date).count,
                               isToday: Self.cal.isDateInToday(date)))
        }
        // 补到固定 6 行。补到 7 的倍数的话，5 行和 6 行的月份高度不一样，翻页时
        // 整张卡会跳；跟手翻页更受不了——拖到一半时相邻两个月并排，一高一低。
        while out.count < Self.rowsPerMonth * 7 { out.append(blank(out.count)) }
        return out
    }

    // MARK: - 尺寸

    private static let cellSpacing: CGFloat = 6
    /// 月历固定画 6 行。
    private static let rowsPerMonth = 6

    /// 单个日期格的高度。
    ///
    /// 固定 50 是照竖屏调的。横屏分栏之后左栏有整屏高度可用，50pt 的格子只占到
    /// 上面一小块，下面大片空着——月历看着像贴在角上的一张小卡。按可用高度摊开，
    /// 上限 96 免得格子大到只剩空白。
    private var cellHeight: CGFloat {
        guard isSideBySide else { return 50 }
        // 卡片上下留白 32 + 月份标题 ~44 + 星期行 ~20 + 卡片外留白 ~32 + 富余
        let chrome: CGFloat = 190
        let perRow = (size.height - chrome) / CGFloat(Self.rowsPerMonth) - Self.cellSpacing
        return min(96, max(50, perRow))
    }

    private var gridHeight: CGFloat {
        CGFloat(Self.rowsPerMonth) * cellHeight
            + CGFloat(Self.rowsPerMonth - 1) * Self.cellSpacing
    }


    // MARK: - Selected day listings

    @ViewBuilder
    private func dayListings(for date: Date) -> some View {
        let listings = store.listings(on: date)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(longDateLabel(date)).font(.headline)
                Spacer()
                Text("\(listings.count) listings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if listings.isEmpty {
                Text("No move-in on this day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(listings) { l in
                    Button {
                        if UIDevice.current.userInterfaceIdiom == .pad {
                            coord.openListing(id: l.id, titleHint: l.name)
                        } else {
                            coord.listingsPath.append(.byId(l.id, titleHint: l.name))
                        }
                    } label: {
                        listingRow(l)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private func listingRow(_ l: CalendarListing) -> some View {
        HStack(alignment: .top, spacing: isRegular ? 16 : 12) {
            VStack(alignment: .leading, spacing: isRegular ? 6 : 4) {
                HStack(spacing: isRegular ? 8 : 6) {
                    Text(l.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    PlatformBadge(source: l.source, size: .small)
                }
                // OurCampus 的 city 和 building 是同一个值，而标题里也有它——
                // 原来这里会把同一件事念三遍。去重逻辑见 PlaceSummary。
                if let place = PlaceSummary.text(name: l.name,
                                                 parts: [l.building, l.city]) {
                    Text(place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(l.status)
                    .font(.caption2)
                    .foregroundStyle(statusColor(for: l.status))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if !l.priceRaw.isEmpty {
                    Text(l.priceRaw)
                        .font(.subheadline.weight(.semibold))
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, isRegular ? 16 : 10)
        .padding(.horizontal, isRegular ? 18 : 14)
        .liquidGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func statusColor(for status: String) -> Color {
        ListingStatus.from(status).color
    }


    // MARK: - Helpers

    /// 翻一个月。箭头按钮和滑动手势都走这里，动画只有一套。
    ///
    /// 手法是「先瞬间换月 + 反向补偿偏移，再把偏移动画回 0」：换月之后同一个月份
    /// 在带子里的位置移动了一屏，补上 `delta * width` 正好抵消，视觉上没有跳变；
    /// 然后动画把偏移收回 0，看起来就是那一屏滑了过去。
    ///
    /// 这样手势松手和按钮点击落在同一条路径上——不必一个用 transition、一个用
    /// offset，那样两种翻页的手感会不一样。
    /// 落定动画。
    ///
    /// `.snappy` 是个固定时长的弹簧，不管手指甩得多快、还剩多远，都用同一条曲线
    /// 走完——快扫之后那一下会显得"追不上手"，慢拖到边缘再松手又显得拖沓。
    /// 换成按**剩余距离和当前速度**给 response：手甩得快、剩得少 → 短促收尾；
    /// 慢慢拖到一半松手 → 稍长一点，不至于突兀。
    ///
    /// dampingFraction 0.86：略低于临界阻尼，收尾时有一点点回弹，读起来像是
    /// "吸"过去的而不是"停"在那儿。再低就会明显晃。
    private static func settle(distance: CGFloat, velocity: CGFloat,
                               width: CGFloat) -> Animation {
        let remaining = max(0, width - distance) / max(width, 1)   // 0…1
        let speed = min(abs(velocity) / 2_000, 1)                  // 0…1
        let response = 0.22 + Double(remaining) * 0.16 - Double(speed) * 0.10
        return .spring(response: max(0.16, response), dampingFraction: 0.86)
    }

    /// 翻一个月。箭头按钮和滑动手势都走这里，动画只有一套。
    ///
    /// 手法是「先瞬间换月 + 反向补偿偏移，再把偏移动画回 0」：换月之后同一个月份
    /// 在带子里的位置移动了一屏，补上 `delta * width` 正好抵消，视觉上没有跳变；
    /// 然后动画把偏移收回 0，看起来就是那一屏滑了过去。
    private func shiftMonth(_ delta: Int, velocity: CGFloat = 0, width: CGFloat? = nil) {
        guard let next = Self.cal.date(byAdding: .month, value: delta, to: anchor) else { return }
        let w = width ?? gridWidth
        let travelled = abs(dragOffset)
        anchor = Self.startOfMonth(for: next)
        dragOffset += CGFloat(delta) * w
        isSwiping = true
        withAnimation(Self.settle(distance: travelled, velocity: velocity, width: w)) {
            dragOffset = 0
        } completion: {
            withAnimation(.easeOut(duration: 0.16)) { isSwiping = false }
        }
        selectedDay = nil
    }

    /// 仅当数据范围允许时才能切换；防止用户翻到没数据的月份。
    private func canShiftMonth(_ delta: Int) -> Bool {
        guard let range = store.dateRange else { return false }
        guard let target = Self.cal.date(byAdding: .month, value: delta, to: anchor) else { return false }
        let targetStart = Self.startOfMonth(for: target)
        let limitStart = Self.startOfMonth(for: delta < 0 ? range.start : range.end)
        return delta < 0
            ? targetStart >= limitStart
            : targetStart <= limitStart
    }

    private func monthTitle(for date: Date) -> String {
        Self.monthTitleFormatter.string(from: date)
    }

    private func longDateLabel(_ date: Date) -> String {
        Self.longDateFormatter.string(from: date)
    }

    /// 周一在前 / 周日在前等顺序符号；本地化无关，统一英文短名。
    private func orderedWeekdaySymbols() -> [String] {
        let symbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let first = Self.cal.firstWeekday - 1   // 1..7 → 0..6
        return Array(symbols[first...] + symbols[..<first])
    }

    /// 生成当前 anchor 月所有日期 + 月首前后的占位单元（保证 7 列对齐）。

    private static func startOfMonth(for date: Date) -> Date {
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }
}

/// 一格的**预计算**结果。
///
/// 日期数字、当天房源数、是否今天——这三样都要走 Calendar 或 DateFormatter，
/// 放在视图 body 里算就意味着每帧算 126 次（三个月 × 42 格）。提前算好存进值
/// 类型，拖动时只是读。
struct DayCell: Identifiable, Equatable {
    /// 在这 42 格里的下标。补白格也要有稳定 id，不然 ForEach 会错位。
    let id: Int
    /// nil = 补白格。
    let date: Date?
    let day: Int
    let count: Int
    let isToday: Bool
}

/// 一个月的格子。
///
/// 单独成一个 `Equatable` 视图，是为了让 SwiftUI 在输入没变时**整块跳过重绘**。
/// 跟手翻页每帧都在改父视图的 `dragOffset`，而三张月历的输入一个都没动——不做
/// 这层隔离的话，每帧 126 格全部重建，手感就是一顿一顿的。
private struct MonthGrid: View, Equatable {
    let cells: [DayCell]
    let selectedDay: Date?
    let cellHeight: CGFloat
    let width: CGFloat
    /// false = 拖动中，只画日期数字。
    ///
    /// 每格的完整形态包含 `glassEffect`（模糊 + 折射）、圆角背景、描边 overlay
    /// 和一个 spring 动画。三个月 126 格，每帧全部重新合成——这是**渲染**开销，
    /// 在 CPU 占用上看不见，所以「CPU 不高但依然卡」。
    ///
    /// 拖动时这些装饰也没什么用：内容在动，框和数字跟着糊过去，读不出信息。
    /// 松手落定之后再显示，既省掉每帧合成，视觉上也更干净。
    let detailed: Bool
    let onSelect: (Date) -> Void

    /// 比较不含 `onSelect`：闭包没法比，而它捕获的只是 `selectedDay` 的 setter，
    /// 不影响这一格该画成什么样。
    static func == (a: MonthGrid, b: MonthGrid) -> Bool {
        a.cells == b.cells
            && a.selectedDay == b.selectedDay
            && a.cellHeight == b.cellHeight
            && a.width == b.width
            && a.detailed == b.detailed
    }

    private static let cal = Calendar.current
    private static let spacing: CGFloat = 6

    /// VoiceOver 日期朗读格式器。DateFormatter 创建昂贵，static 复用一份。
    private static let a11yDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateStyle = .full
        f.timeStyle = .none
        return f
    }()
    private static let columns = Array(
        repeating: GridItem(.flexible(), spacing: spacing), count: 7)

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: Self.spacing) {
            ForEach(cells) { cell in
                if let date = cell.date {
                    dayCell(cell, date: date)
                } else {
                    Color.clear.frame(height: cellHeight)
                }
            }
        }
        .padding(.horizontal)
        .frame(width: width)
    }

    @ViewBuilder
    private func dayCell(_ cell: DayCell, date: Date) -> some View {
        if detailed {
            fullCell(cell, date: date)
                // 落定之后框和计数淡入，而不是"啪"地一下出现。切换发生在
                // withAnimation 里（见 monthSwipe / shiftMonth 的 completion）。
                .transition(.opacity)
        } else {
            // 拖动中的简化态。保留同样的 VStack 结构和占位行，高度才不会在
            // 松手那一刻跳一下。
            VStack(spacing: 2) {
                Text("\(cell.day)")
                    .font(.subheadline)
                    .foregroundStyle(cell.count == 0 ? Color.secondary : Color.primary)
                Text(" ").font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: cellHeight)
        }
    }

    private func fullCell(_ cell: DayCell, date: Date) -> some View {
        let selected = selectedDay.map { Self.cal.isDate($0, inSameDayAs: date) } ?? false
        let count = cell.count
        return Button {
            onSelect(date)
        } label: {
            VStack(spacing: 2) {
                Text("\(cell.day)")
                    .font(.subheadline)
                    .fontWeight(selected ? .bold : .regular)
                    // 选中态**不用白字**。玻璃是透光的，白字的对比度会随底下
                    // 内容变——筛选 chip 上已经踩过。改成强调色加粗：色相
                    // 表示"选中"，对比度交给系统的中性玻璃保证。
                    .foregroundStyle(
                        selected ? Color.accentColor :
                            (count == 0 ? Color.secondary : Color.primary))
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(selected ? 1 : 0.85)
                } else {
                    Text(" ").font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: cellHeight)
            // 选中态用玻璃，但**不给玻璃着色**——色相由上面的文字承担。
            // 有房源但未选中的那些用一层很淡的强调色底，和空格子区分开。
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(!selected && count > 0
                          ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .modifier(SelectedDayGlass(active: selected))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(cell.isToday && !selected ? Color.accentColor : .clear,
                                  lineWidth: 1.5)
            )
            .animation(.spring(duration: 0.2), value: selected)
        }
        .buttonStyle(.plain)
        // VoiceOver: 把整个格子当单个元素，朗读"<日期> · N listing(s) available"。
        // 不然 VO 会分别朗读里面的两个 Text（日期数字 + 计数），缺乏上下文。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.describe(date: date, count: count, isToday: cell.isToday))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private static func describe(date: Date, count: Int, isToday: Bool) -> String {
        var parts: [String] = [Self.a11yDateFormatter.string(from: date)]
        if isToday { parts.append("Today") }
        switch count {
        case 0: parts.append("No listings available")
        case 1: parts.append("1 listing available")
        default: parts.append("\(count) listings available")
        }
        return parts.joined(separator: ", ")
    }
}

private enum CalendarCell: Identifiable, Hashable {
    case empty(Int)
    case day(Date)

    var id: String {
        switch self {
        case .empty(let index):
            return "empty-\(index)"
        case .day(let date):
            return "day-\(Int(date.timeIntervalSince1970))"
        }
    }
}


/// 选中那一天的玻璃底。
///
/// 单独抽成 ViewModifier，是因为 `liquidGlass` 只能在选中时加——写成行内的
/// `if` 会把 background 链拆成两条分支，SwiftUI 会当成两个不同的视图，选中/
/// 取消时整格重建，动画跳变。
private struct SelectedDayGlass: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.liquidGlass(RoundedRectangle(cornerRadius: 14, style: .continuous),
                                interactive: true)
        } else {
            content
        }
    }
}
