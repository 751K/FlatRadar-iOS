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
