import SwiftUI

/// 入住日历视图。
///
/// 布局
/// ----
/// 1. 月历：``NativeMonthCalendar``（原生 ``UICalendarView``）。月份标题、前后
///    箭头、滑动翻页、周首日本地化都由它自己管；每天下面的可入住数是我们挂上去
///    的装饰。
/// 2. 选中日的房源列表（点单条进 ListingDetailView via deep link）。
///
/// 横屏 ≥700pt 时两者左右分栏，否则上下排。
///
/// 这里原来是一整套手写月历——月份切换条、7 列表头、42 格的网格、跟手翻页的
/// 三联带子，外加为它调优的预计算和降级渲染。换成原生之后那些全部删掉了，
/// 沿革见 `NativeMonthCalendar` 的文件头和那条 commit。
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
    /// 自动选中只做一次。不加这道门的话，用户翻月份（会清掉 selectedDay）之后
    /// 碰上一次刷新，就会被拽回自动选的那天。
    @State private var didAutoSelect = false

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = ServerTime.timeZone
        return c
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

    /// 把月历和当日房源左右分栏。
    ///
    /// 判据从「横屏」放宽成「放得下」
    /// ------------------------------
    /// 原来是 `width >= 700 && width > height`，只有横屏分栏。理由是横屏缺纵向
    /// 空间：月历高度固定，吃掉上半屏之后当日房源挤在下面一条缝里。
    ///
    /// 但竖屏 iPad 是另一种浪费：月网格**宽度也是固定的**（默认字号 391pt，多给
    /// 的只变成留白），所以 834 甚至 1024 的竖屏上，月历只占中间一小条，两侧
    /// 大片空白，下面才是房源。分栏之后两边都用得上。
    ///
    /// 所以判据只剩「两列都放得下」：
    ///
    /// - 左栏 ≥ 网格宽 + 卡片左右留白（``calendarColumnFloor``）
    /// - 右栏 ≥ 350pt，够放下一行「名字 + 地点 + 状态 + 价格」
    ///
    /// 默认字号下合计约 773pt。落点：iPhone 竖屏 393 不分栏、iPhone 横屏 852
    /// 分栏（和以前一样）、iPad mini 竖屏 744 **不**分栏（分了右栏只剩 321pt）、
    /// iPad 11 寸竖屏 834 和 13 寸竖屏 1024 分栏、Split View 半屏 570 不分栏。
    private var isSideBySide: Bool { size.width >= calendarColumnFloor + 350 }

    /// 左栏的下限：一整个月网格 + 卡片左右留白。
    ///
    /// 比这还窄的话月历不是缩小而是**被切掉**——见
    /// ``NativeMonthCalendar/nominalGridWidth``。
    private var calendarColumnFloor: CGFloat {
        NativeMonthCalendar.nominalGridWidth + 2 * Self.cardHorizontalPadding
    }

    /// 分栏时左栏的宽度。
    ///
    /// 比例分两档：横屏 2:3（偏向房源），竖屏 1:1。竖屏给月历多一点是因为那边
    /// 纵向不缺，两列等宽读起来最稳；横屏纵向紧张，房源列多拿一点能多显示一行。
    ///
    /// 外面再套一个 ``calendarColumnFloor`` 的下限。这不是保守，是必需的：
    /// 按比例算出来的值可能比网格还窄——iPhone 横屏 852×0.4 = 341，iPad mini
    /// 竖屏 744×0.5 = 372，都不到 391。以前没这条，那两档其实是把月历切了一角，
    /// 只是没人报过。
    private var calendarColumnWidth: CGFloat {
        let ratio: CGFloat = size.width > size.height ? 2.0 / 5.0 : 1.0 / 2.0
        return max(size.width * ratio, calendarColumnFloor)
    }

    /// 月历卡的左右留白。左栏宽度要算进它，所以提成常量。
    private static let cardHorizontalPadding: CGFloat = 16

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
                    .frame(width: calendarColumnWidth)

                    Divider()

                    ScrollView {
                        dayPane.padding(.vertical)
                    }
                    .refreshable { await store.refresh() }
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        calendarCard
                        dayPane
                    }
                    .padding(.vertical)
                }
                .refreshable { await store.refresh() }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .refreshable { await store.refresh() }
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
            autoSelectFirstDayWithListings()
        }
        // 预热路径：数据可能在这个视图出现之前就到了，那时上面的 .task 里
        // listings 已经非空、不会再 fetch，但选中还没做过。
        .onChange(of: store.listings.count) { _, _ in
            autoSelectFirstDayWithListings()
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

    /// 拿到数据后自动选中**一个有房源的日子**。
    ///
    /// 修的是 build 293 截图里同时暴露的两件事：
    ///
    /// 1. **月份不对。** 截图上日历停在 8 月，而右上角 "Today" 是禁用态——那个
    ///    按钮的禁用条件正是「anchor 就是当前月」，也就是说 anchor 在 9 月而
    ///    `UICalendarView` 显示 8 月，视图和状态脱节了。推测是设
    ///    `availableDateRange` 时 UIKit 把可见月吸附到了范围起点（数据最早在
    ///    8 月），而 `NativeMonthCalendar` 里那道「只在 lastReportedMonth 变了
    ///    才 setVisibleDateComponents」的守卫没接住这次吸附。
    /// 2. **右栏空着。** 没有选中日 → 右栏只有一句 "Tap a day…"，横屏分栏后
    ///    大半屏是空的。
    ///
    /// 一次修两件：选中某天会让 `setSelected` 把日历滚到那天所在的月（头文件：
    /// "Sets the selected date to be displayed in the calendar"），月份跟着对；
    /// 右栏也有内容了。
    ///
    /// **`anchor` 一起设**，不靠 delegate 回写：程序触发的滚动不一定会走
    /// `didChangeVisibleDateComponentsFrom`（它的文档写的是 "from user
    /// interaction"），不显式同步的话就会重演上面那个脱节。
    ///
    /// 选哪天：今天或今天之后**第一个**有房源的日子；全都在过去就选最后一个。
    /// 不选「房源最多的那天」——那样每次刷新可能跳到不同的月份，用户会莫名其妙。
    private func autoSelectFirstDayWithListings() {
        guard !didAutoSelect, selectedDay == nil, !store.listings.isEmpty else { return }
        let days = Set(store.listings.compactMap(\.date).map(Self.cal.startOfDay))
            .sorted()
        guard let pick = days.first(where: { $0 >= Self.cal.startOfDay(for: Date()) })
                ?? days.last else { return }
        didAutoSelect = true
        selectedDay = pick
        anchor = Self.startOfMonth(for: pick)
    }

    // MARK: - 月历

    /// 月历那张卡。
    ///
    /// 卡片边框是自己画的：月历原先是月份标题 / 星期行 / 日期格三块各自平铺在
    /// 页面上，没有边界，读起来是一堆散元素而不是「一个月历」。大面板用实体表面
    /// 而不是玻璃——玻璃在大面积上会把自己的内容也搅浑（地图那张说明卡踩过）。
    ///
    /// **`store.dateRange` 那一行同时是数据订阅**：`countForDay` 是个闭包，
    /// body 求值时并不读 `listings`，所以如果这里不读一次 `dateRange`（它内部
    /// 遍历 `listings`），@Observable 就不会把这个视图登记为 `listings` 的
    /// 观察者——刷新拿到新数据后日期下面的数字不会重画。原先靠一条
    /// `.onChange(of: store.listings.count)` 显式触发重算，那是手写版留下的，
    /// 已经删了。
    private var calendarCard: some View {
        NativeMonthCalendar(
            selectedDay: $selectedDay,
            visibleMonth: $anchor,
            availableRange: store.dateRange,
            countForDay: { store.listings(on: $0).count }
        )
        // 宽度上限由 NativeMonthCalendar 自己卡（容器在布局时实测月网格的页宽），
        // 这里不再写死一个数——写死过 420（太窄）、460 / 640（会露出相邻月份）。
        .padding(.vertical, 8)
        // 卡片底**贴着日历本身**，不是撑满整列。顺序反过来的话（先撑满再画底）
        // 卡片会横跨整个左栏，而里面的日历只占中间那一段，两边各空一截。
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .frame(maxWidth: .infinity)   // 画完底再在列里居中
        .padding(.horizontal, Self.cardHorizontalPadding)
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

    private func longDateLabel(_ date: Date) -> String {
        Self.longDateFormatter.string(from: date)
    }

    private static func startOfMonth(for date: Date) -> Date {
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }
}
