import SwiftUI
import FlatRadarCore

/// 入住日历视图。
///
/// 布局
/// ----
/// 1. 月历：``SwiftUIMonthCalendar``。七列日期网格会填满卡片宽度，月份标题、前后
///    箭头、滑动翻页、周首日本地化和房源数都由 SwiftUI 绘制。
/// 2. 选中日的房源列表（点单条进 ListingDetailView via deep link）。
///
/// 宽度足够时两者左右分栏，否则上下排。
///
/// 与 Map 共享一个交互模式：点元素弹底层 sheet，从 sheet 进详情走
/// ``NavigationCoordinator.openListing`` 复用 Listings tab 的 NavigationStack。
struct CalendarView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(NavigationCoordinator.self) private var coord
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// 状态色当文字用时要按明暗压暗/提亮，见 ``Color/onSurface(in:)``。
    @Environment(\.colorScheme) private var scheme

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

    /// 分栏前要求月历列至少能舒适地排下七列日期。它只是布局下限；SwiftUI 网格
    /// 会继续随卡片宽度伸展，不再受 UIKit 月网格的 391pt 上限限制。
    @ScaledMetric(relativeTo: .body) private var minimumCalendarGridWidth: CGFloat = 370

    @State private var anchor: Date = Self.startOfMonth(for: Date())
    @State private var selectedDay: Date?
    @State private var showRefreshError = false
    /// 自动选中只做一次。不加这道门的话，用户翻月份（会清掉 selectedDay）之后
    /// 碰上一次刷新，就会被拽回自动选的那天。
    @State private var didAutoSelect = false

    /// 见 ``ServerTime/calendar``——和 SwiftUI 月历共用同一份服务端时区日历。
    private static let cal = ServerTime.calendar

    /// 完整日期，跟随系统语言（en："Wednesday, May 14, 2026"，
    /// zh-Hans："2026年5月14日星期三"）。
    ///
    /// **locale 是 `.autoupdatingCurrent`，不是 `en_US_POSIX`。** 原先锁的是
    /// POSIX，于是右栏那行日期抬头在任何语言下都是英文——build 295 的中文截图
    /// 里，一屏中文界面正中间戳着 "Monday, September 7, 2026"。
    ///
    /// `en_US_POSIX` 是给**解析**固定格式用的（保证 `dateFormat` 不被用户的
    /// 区域设置改写），这个仓库里其余几处都是那种用法、都是对的；用在
    /// `dateStyle` 这种**显示**形态上就成了「把界面钉死在英文」。
    private static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = .autoupdatingCurrent
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
    /// 但竖屏 iPad 是另一种浪费：月网格过去不会随卡片变宽，导致屏幕两侧留白。
    /// SwiftUI 网格现在会铺满左栏，分栏后两边都用得上。
    ///
    /// 所以判据只剩「两列都放得下」：
    ///
    /// - 左栏 ≥ 可读的网格宽度 + 卡片左右留白（``calendarColumnFloor``）
    /// - 右栏 ≥ 350pt，够放下一行「名字 + 地点 + 状态 + 价格」
    ///
    /// 默认字号下合计约 752pt。落点：iPhone 竖屏不分栏、iPhone 横屏分栏，iPad mini
    /// 竖屏保持上下布局，较宽的 iPad 竖屏和 iPad 横屏分栏，Split View 半屏不分栏。
    private var isSideBySide: Bool { size.width >= calendarColumnFloor + 350 }

    /// 左栏的舒适宽度下限，加卡片左右留白。它不限制网格最大宽度。
    private var calendarColumnFloor: CGFloat {
        minimumCalendarGridWidth + 2 * Self.cardHorizontalPadding
    }

    /// 分栏时左栏的宽度。
    ///
    /// 比例分两档：横屏 2:3（偏向房源），竖屏 1:1。竖屏给月历多一点是因为那边
    /// 纵向不缺，两列等宽读起来最稳；横屏纵向紧张，房源列多拿一点能多显示一行。
    ///
    /// 外面再套一个 ``calendarColumnFloor`` 的下限，避免分栏后日期列过窄。
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
                                          toGranularity: .month)
                          && selectedDay.map { Self.cal.isDateInToday($0) } == true)
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
    /// 自动选日时同时同步日期与月份：
    ///
    /// 1. **月份显式同步。** 选中日期和可见月份是两份 SwiftUI 状态，所以这里
    ///    一起设置，不依赖日历控件内部滚动来同步月份。
    /// 2. **右栏有内容。** 没有选中日 → 右栏只有一句 "Tap a day…"，横屏分栏后
    ///    大半屏是空的。
    ///
    /// 选中日期和月份一起设置，右栏会有内容且标题、网格状态保持同步。
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
    /// 读取 `store.dateRange` 会让这个视图观察列表刷新；`countForDay` 是闭包，
    /// 本身不会在这里访问 `listings`。数据变化后重算日期格和房源数；下面那条
    /// `.onChange(of: store.listings.count)` 只负责首次自动选日。
    private var calendarCard: some View {
        SwiftUIMonthCalendar(
            selectedDay: $selectedDay,
            visibleMonth: $anchor,
            availableRange: store.dateRange,
            countForDay: { store.listings(on: $0).count }
        )
        // 七列按卡片可用宽度等分，卡片会随所在列展开。
        .padding(.vertical, 8)
        // 卡片底随月历一起铺开。
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
        LazyVStack(alignment: .leading, spacing: 8) {
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
                        // 判据在 coordinator 里，不在这里猜设备——
                        // 见 ``NavigationCoordinator/showListing(id:titleHint:)``。
                        coord.showListing(id: l.id, titleHint: l.name)
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
                // 后端原样透出来的 status（"Occupied" / "Direct book" …）不是
                // 可本地化的 key，直接显示就是所有语言都看到英文——build 302 的
                // 中文截图里，一列中文房源卡上戳着 "Occupied"。
                // 走 ListingStatus 的本地化标签，和它旁边的 statusColor 同源。
                Text(ListingStatus.from(l.status).label)
                    .font(.caption2)
                    .foregroundStyle(statusColor(for: l.status))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if !l.priceRaw.isEmpty {
                    Text(PriceText.compact(l.priceRaw) ?? l.priceRaw)
                        .font(.subheadline.weight(.semibold))
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, isRegular ? 16 : 10)
        .padding(.horizontal, isRegular ? 18 : 14)
        // 卡底用**分组表格的次级底色**，不是玻璃。
        //
        // 规范里这条是明写的：玻璃属于浮在内容之上的功能层（工具栏、悬浮控件），
        // 内容本身——卡片、行、正文——用 `background-secondary` /
        // `grouped-background-secondary`。这些是日历下面的房源行，是内容。
        //
        // 而且它真的在花钱：玻璃把底垫亮之后，行里那句 `.secondary` 的城市名
        // 实测只有 **2.95:1**，比 Apple 给 label-secondary 的 3.5:1 还低一档。
        // 换成不透明的卡底，同一个语义色就回到它该有的对比度。
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 行里那行状态文字的颜色。
    ///
    /// 不能直接用状态色：`Occupied`（系统灰）实测 **3.03:1**，而这行是 11pt。
    /// 规范里那句是"`gray` 3.2:1：符号和分隔线可以，文字不行"。压暗一档，
    /// 见 ``Color/onSurface(in:)``。
    private func statusColor(for status: String) -> Color {
        ListingStatus.from(status).color.onSurface(in: scheme)
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
