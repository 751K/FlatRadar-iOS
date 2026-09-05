import SwiftUI

struct DashboardView: View {
    @Environment(DashboardStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @Environment(NavigationCoordinator.self) private var coord
    @Environment(\.colorScheme) private var colorScheme
    /// iOS"减弱动效"开关（设置 → 辅助功能 → 动效 → 减弱动效）。
    /// 启用时关闭呼吸/脉冲一类的循环动画，避免触发前庭功能敏感的用户。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 心跳点呼吸动画的相位（true ↔ false 反复切换驱动 .scaleEffect / .opacity）。
    @State private var liveDotBreathing = false

    /// Cached chart data for inline mini visualizations.
    @State private var chartDailyNew: ChartData?
    @State private var chartSource: ChartData?
    @State private var chartStatus: ChartData?
    @State private var chartPrice: ChartData?
    @State private var chartType: ChartData?
    @State private var chartEnergy: ChartData?
    @State private var chartTenant: ChartData?
    @State private var matchedPreviews: [Listing] = []
    @State private var activeChart: ChartDetail?
    /// "New · 24h" / "New · 7d" / "Changes" 三个 mini stat 点开后的 detail sheet
    @State private var activeRecentMode: RecentActivityMode?

    // MARK: - Derived chart data (cached to avoid re-sorting on every body invalidation)
    //
    // Dashboard body 在 store 任何字段变化时都重算（SSE 推通知 → store 间接通知 →
    // dashboard re-render）。如果让 mini card 在 view body 里调 .sorted() / .bucketed()
    // ，5 张图每 SSE batch 就重排一遍 → 主线程 10-15ms。
    //
    // 这里把"派生数据"提前算好缓存：onChange 监听原始 chartXxx 变化时刷新；
    // body 直接消费数组，O(1)。
    @State private var statusBuckets: [ChartEntry] = []   // {available, lottery, other} 计数
    @State private var statusBucketsTotal: Int = 0
    @State private var sourceBuckets: [ChartEntry] = []
    @State private var priceSortedAsc: [ChartEntry] = []
    @State private var typeTopThree: [ChartEntry] = []
    @State private var energyMerged: [ChartEntry] = []
    @State private var tenantTopThree: [ChartEntry] = []
    @State private var weekGrowthCached: String? = nil

    /// Dashboard **自己**的导航栈。
    ///
    /// Your matches 里点一套房，以前走 `coord.openListing(id:)`——那个方法会
    /// `selectedTab = .listings` 再把路径塞进 Listings 那个栈里，所以详情页是在
    /// **另一个 tab** 里打开的，返回键自然回到 Listings，回不到 Dashboard。
    ///
    /// 那个行为对深链接和「在地图上查看」是对的（它们本来就要换 tab），对这里
    /// 不对：从 Dashboard 点进去就该在 Dashboard 里返回。所以这里 push 到自己
    /// 的栈上。
    ///
    /// 注：`RecentActivitySheet`（New · 24h / Changes 两个 sheet）里点房源仍然
    /// 走 `coord.openListing`——它得先 dismiss 自己，dismiss 之后没有栈可 push。
    @State private var listingPath: [ListingRoute] = []

    /// 分栏时左栏（大数字卡 + Explore）的实测高度，用来把右栏那张卡拉到同样高。
    ///
    /// 为什么要量而不是让它自己撑：HStack 里写 `maxHeight: .infinity` 在
    /// ScrollView 里是无界的，会把无穷大一路提给子视图算尺寸（Dashboard 的
    /// sparkline 踩过这个，见 statsCard 竖排分支的注释）。量出来是个具体数，
    /// 没有这个风险。
    ///
    /// 不会形成循环：右栏多高不影响左栏，左栏高度只由自己的内容决定。
    @State private var leftColumnHeight: CGFloat = 0

    struct ChartDetail: Identifiable {
        let id = UUID()
        let key: String
        let title: String
        let subtitle: String?
        let days: Int
    }

    var body: some View {
        NavigationStack(path: $listingPath) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if store.isLoading && store.summary == nil {
                            ProgressView().padding(.top, 80).frame(maxWidth: .infinity)
                        } else if let err = store.errorMessage, store.summary == nil {
                            errorView(err)
                        } else {
                            headerRow
                            liveBadge
                            dashboardBody(proxy.size)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .refreshable { await refresh() }
                .background(Color(.systemGroupedBackground))
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: ListingRoute.self) { route in
                    ListingDetailView(route: route)
                }
                .task { await refresh() }
                .sheet(item: $activeChart) { detail in
                    ChartDetailView(chartKey: detail.key,
                                    title: detail.title,
                                    subtitle: detail.subtitle,
                                    days: detail.days)
                        .presentationDetents([.fraction(0.65), .large])
                        .presentationDragIndicator(.visible)
                }
                .sheet(item: $activeRecentMode) { mode in
                    RecentActivitySheet(mode: mode)
                        .presentationDetents([.fraction(0.75), .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }

    // MARK: - Greeting

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let name = auth.userInfo?.name ?? ""
        let prefix: String
        switch hour {
        case 5..<12: prefix = String(localized: "Good morning")
        case 12..<17: prefix = String(localized: "Good afternoon")
        default:      prefix = String(localized: "Good evening")
        }
        return name.isEmpty ? prefix : "\(prefix), \(name)"
    }

    // MARK: - User pill

    @ViewBuilder
    private var userPill: some View {
        let label: String = {
            if auth.isAdmin { return "Admin" }
            if auth.isGuest { return "Guest" }
            return auth.userInfo?.name ?? "User"
        }()
        let initial: String = {
            if auth.isGuest { return "G" }
            if auth.isAdmin { return "A" }
            return String(auth.userInfo?.name.prefix(1) ?? "U").uppercased()
        }()

        if auth.isGuest {
            Menu {
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right",
                       role: .destructive) {
                    Task { await auth.logout() }
                }
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.secondary.opacity(0.12)).frame(width: 28, height: 28)
                        Text(initial)
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    }
                    Text("Guest")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.2), lineWidth: 1))
            }
            .menuOrder(.fixed)
        } else {
            Menu {
                Section { Text(label) }
                Button("Log out", systemImage: "rectangle.portrait.and.arrow.right",
                       role: .destructive) {
                    Task { await auth.logout() }
                }
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(auth.isAdmin ? Color.red.opacity(0.12) : Color.blue.opacity(0.12))
                            .frame(width: 28, height: 28)
                        Text(initial)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(auth.isAdmin ? .red : .blue)
                    }
                    Text(label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.2), lineWidth: 1))
            }
            .menuOrder(.fixed)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Dashboard")
                    .font(.system(size: 28, weight: .heavy))
                    .tracking(-0.8)
                Spacer()
                if auth.isAuthenticated {
                    userPill
                }
            }
            Text(greeting)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8).padding(.bottom, 14)
    }

    // MARK: - Live badge

    private var liveBadge: some View {
        let s = store.summary
        // 刷新失败时只把心跳点换橙色 + 文字 "Offline"，不再弹 modal alert
        // 打断用户。store 在 fetch 失败时不会清空 summary，所以页面数据仍可用，
        // 用户感知到的就是"数据稍微过期了"。
        let isStale = store.errorMessage != nil
        let dotColor: Color = isStale ? .orange : .green
        let statusText: String = isStale ? "Offline" : "Live"

        // 呼吸动画只在 Live + 未启用减弱动效时跑。
        // - Offline 时停止：让用户视觉上一眼分辨"动 = 数据新鲜"/"静 = 数据过期"
        // - reduceMotion=true 时停止：iOS HIG 要求循环动画必须被这个开关
        //   抑制；前庭功能敏感的用户开了它才能舒服使用 app
        let animatesLiveDot = !isStale && !reduceMotion

        return HStack(spacing: 7) {
            ZStack {
                // 外层光晕：放大 + 渐隐反复，营造心跳脉冲感
                if animatesLiveDot {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 10, height: 10)
                        .scaleEffect(liveDotBreathing ? 2.4 : 1.0)
                        .opacity(liveDotBreathing ? 0.0 : 0.45)
                        .animation(
                            .easeOut(duration: 1.6)
                                .repeatForever(autoreverses: false),
                            value: liveDotBreathing
                        )
                }
                // 内层实心点：固定大小 + 轻微缩放，避免外层光晕让中心点也跟着抖
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .scaleEffect(animatesLiveDot && liveDotBreathing ? 1.12 : 1.0)
                    .animation(
                        animatesLiveDot
                            ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                            : .default,
                        value: liveDotBreathing
                    )
                    .shadow(color: dotColor.opacity(0.4), radius: 7, x: 0, y: 0)
            }
            .frame(width: 10, height: 10)   // 锁定布局尺寸，光晕只在视觉上溢出
            Text(statusText)
                .fontWeight(isStale ? .semibold : .regular)
                .foregroundStyle(isStale ? .orange : .primary)
            Text("·")
            Text("updated \(relativeTime(s?.lastScrape ?? ""))")
        }
        .font(.subheadline)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .overlay(Capsule().strokeBorder(.secondary.opacity(0.15), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        // VoiceOver：默认会把绿圈 / Live / · / updated 8m 分四次朗读。combine
        // 后只剩一个元素，再叠 a11yLabel 拼成 "Live, updated 8 minutes ago"
        // 这种自然短句（Offline 时变成 "Offline, updated …"）。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(statusText), updated \(relativeTime(s?.lastScrape ?? ""))")
        // 一进 onAppear 触发 toggle，由 .animation(.repeatForever) 拉动循环。
        // 注意：不在 .task 里写——iOS 17 之后 .task 可能比 view 出现晚一帧，
        // onAppear 时机更稳。
        .onAppear {
            if animatesLiveDot {
                liveDotBreathing = true
            }
        }
        // 离线/在线切换 + reduceMotion 切换时实时停起动画
        .onChange(of: animatesLiveDot) { _, shouldAnimate in
            if shouldAnimate {
                liveDotBreathing = true
            } else {
                // 停下时一并复位状态值，否则下次启动是 true→true，
                // .animation(value:) 不会感知变化，呼吸不起来
                withAnimation(.default) { liveDotBreathing = false }
            }
        }
    }

    /// 单栏时大数字卡该不该排成一行。
    ///
    /// 判据是**朝向 + 放不放得下**，不是绝对宽度
    /// ------------------------------------------
    /// 原来写的是 `availableWidth >= 1000`，而量到的是**正文**宽度，不是屏幕
    /// 宽度——`sidebarAdaptable` 的侧边栏一展开就从里面扣掉约 320pt。iPad 11 寸
    /// 横屏 1194 收起侧边栏走一行、展开后正文只剩 ~874 掉回两行，于是每收放一次
    /// 侧边栏那张卡就换一次排布，而旁边几块只是平滑地改宽度。
    ///
    /// 而且绝对宽度根本分不开这两件事：13 寸**竖屏**是 1024，比 11 寸**横屏**
    /// 展开侧边栏后的 874 还宽——想要「横屏一律一行、竖屏一律两行」，用一条宽度
    /// 线是写不出来的。
    ///
    /// 所以跟 `CalendarView.isSideBySide` 用同一套判据：
    ///
    /// - `width > height`——横排缺的是**纵向**空间，这跟屏幕多大无关。侧边栏展开
    ///   后 874×~746 仍然是横的，Split View 拉成半屏（~570×790）则是竖的，正好
    ///   分别对应该走哪种排布。
    /// - `>= 700`——这是**放不放得下**的下限，不是用来区分设备的：大数字块 ~135
    ///   + 竖分隔 50 + 三个小数 ~246 + 曲线左边距 32 + 卡片左右留白 40 ≈ 500，
    ///   700 之下曲线就只剩一条缝了。跟竖排分支里曲线宽度那个 700 是同一个数。
    ///
    /// 副作用是 iPhone 横屏（852 / 932）也走一行了。这是对的：横屏 iPhone 正文
    /// 高度只有 ~330，两行版要吃掉一大半。SE 那档 667 落在 700 以下，仍是两行。
    private func statsIsWide(_ size: CGSize) -> Bool {
        size.width > size.height && size.width >= Self.statsOneRowMinWidth
    }

    // MARK: - 主体排布

    /// 大数字卡 / Your matches / Explore 三块的排布。
    ///
    /// iPad 横屏左右分栏：左边大数字卡 + Explore，右边 Your matches。三块竖着排
    /// 时 Explore 那六张图要滚很久才露头，而右边大片空着；Your matches 又恰好是
    /// 「一个数 + 几条预览」，天生适合一条窄列。
    ///
    /// 分栏的门槛由左栏倒推：左栏必须 ≥700 才排得下一行版的大数字卡
    /// （见 ``statsIsWide(_:)``），左栏占 3/5，所以整宽要 ≥ 700 / 0.6 ≈ 1167。
    /// 落点是 iPad 11 寸横屏 1194 和 13 寸横屏 1366；iPad mini 横屏 1133 差一点，
    /// 分了左栏只有 680、大数字卡会掉回两行版，不如不分。
    ///
    /// guest 没有 Your matches，右栏会是空的——那种时候不分栏。
    @ViewBuilder
    private func dashboardBody(_ size: CGSize) -> some View {
        if isTwoColumn(size), auth.isUser, let me = store.meSummary {
            let leftWidth = size.width * (1 - Self.matchesColumnRatio)
            let rightWidth = size.width - leftWidth
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    // 量的范围**到最后一张 Explore 卡为止**，不含
                    // "More breakdowns ›"。右栏对齐的是那排卡的底边——按钮是
                    // 一条居中的文字链接，跟它对齐等于右栏比左边的卡多出去
                    // 一截，看着像没对上。所以按钮排在被量的这块外面。
                    VStack(alignment: .leading, spacing: 0) {
                        // wide 直接给 true：门槛已经保证 leftWidth ≥ 700。
                        statsCard(availableWidth: leftWidth, wide: true)
                        exploreSection(availableWidth: leftWidth, showsMore: false)
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        leftColumnHeight = $0
                    }

                    exploreMoreButton.padding(.top, 18)
                }
                .frame(width: leftWidth)

                matchesSection(me, availableWidth: rightWidth, stacked: true,
                               minCardHeight: leftColumnHeight)
                    .frame(width: rightWidth)
            }
        } else {
            statsCard(availableWidth: size.width, wide: statsIsWide(size))
            if auth.isUser, let me = store.meSummary {
                matchesSection(me, availableWidth: size.width)
            }
            exploreSection(availableWidth: size.width)
        }
    }

    /// Your matches 那一栏占的宽度比例——左 3 : 右 2。
    private static let matchesColumnRatio: CGFloat = 2.0 / 5.0

    /// 一行版大数字卡的最小宽度。分栏门槛由它倒推，见 ``dashboardBody(_:)``。
    private static let statsOneRowMinWidth: CGFloat = 700

    private static var twoColumnMinWidth: CGFloat {
        statsOneRowMinWidth / (1 - matchesColumnRatio)
    }

    private func isTwoColumn(_ size: CGSize) -> Bool {
        size.width > size.height && size.width >= Self.twoColumnMinWidth
    }

    // MARK: - Stats card

    /// 顶部大数字卡。
    ///
    /// 横排把「大数字 / 三个小数 / 迷你曲线」放成**一行**。竖排版本在 iPhone 竖屏
    /// 上是对的，但横过来之后大数字贴最左、曲线贴最右，中间空出一大片；下面三个
    /// 小数又被 `maxWidth: .infinity` 拉开到跨越整块屏幕。排成一行之后那些空隙
    /// 变成了卡片本身的宽度，卡高也少了一半。
    ///
    /// `wide` 由调用点给，不在这里算——分栏时左栏的高宽比说明不了任何事情
    /// （一条 716×790 的列并不是"竖屏"），那种时候是门槛保证了它放得下。
    /// 单栏时的判据见 ``statsIsWide(_:)``。
    private func statsCard(availableWidth: CGFloat, wide: Bool) -> some View {
        Group {
            if wide {
                HStack(alignment: .center, spacing: 0) {
                    statsHeadline
                    statsDivider
                    statsMiniRow(spread: false)
                    // 曲线吃掉剩下的全部宽度，而不是固定 220 再拿 Spacer 顶开。
                    // 那段空白本来就没在表达任何东西，交给趋势线之后横屏上它是
                    // 这张卡里信息量最大的一块。SparklineView 是纯 Shape，拉宽
                    // 只会让 7 天的走势更清楚。
                    statsSparkline
                        .frame(maxWidth: .infinity, minHeight: 70, maxHeight: 70)
                        .padding(.leading, 32)
                }
                .padding(20)
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top) {
                        statsHeadline
                        Spacer(minLength: 16)
                        statsSparkline
                            // 竖排时也别写死 130：iPad 竖屏有富余，让曲线占到
                            // 该占的宽度，那段空白本来就没在表达任何东西。
                            //
                            // ⚠️ 顺序不能反：**先定死尺寸，再撑高度居中**。
                            // 写成 `.frame(maxHeight: .infinity)` 在前的话，这里
                            // 外层是 ScrollView（纵向无界），无穷大的高度会一路
                            // 提给 SparklineView 的 Shape 去算路径，后面那个
                            // `.frame(height: 70)` 是收不回来的——原来的写法把
                            // width/height 放在第一位就是为了这个。
                            .frame(width: availableWidth >= 700 ? 320 : 130,
                                   height: 70)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .padding(20)

                    Divider().padding(.horizontal, 20)

                    statsMiniRow(spread: true)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 20)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.secondary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        // `if wide` 的两个分支是**结构不同的两棵子树**（一行 vs 两行、竖分隔 vs
        // 横分隔、小数收紧 vs 等分），SwiftUI 只能把一棵拆掉换上另一棵，没有可
        // 插值的中间态——不给动画就是硬切。
        //
        // 改判据之后收放侧边栏已经不再触发这次切换了（横屏两种状态都是一行），
        // 但转屏还会，Split View 拖动分割线也会。这两种场合下尺寸是从
        // `GeometryReader` 读出来的，不在触发那次变化的 transaction 里，不会
        // 自动继承动画——得靠 `.animation(_:value:)` 盯着 `wide` 自己起一次。
        //
        // 效果是淡入淡出加卡片高度平滑收放。真要让大数字和三个小数**飞到**新
        // 位置，得让两种排布共用同一批子视图再套 `AnyLayout`；现在两边的子视图
        // 和顺序都不一样（一行版里三个小数在曲线前面，两行版在下面），那是一次
        // 结构改动。
        .animation(.smooth(duration: 0.28), value: wide)
    }

    /// TOTAL LISTINGS + 大数字 + 本周涨幅。
    private var statsHeadline: some View {
        let s = store.summary
        return VStack(alignment: .leading, spacing: 6) {
            Text("TOTAL LISTINGS")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.secondary)
                .tracking(1.5)
            Text("\(s?.total ?? 0)")
                .font(.system(size: 58, weight: .heavy))
                .monospacedDigit()
                .tracking(-2)
            if let wg = weekGrowthText {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.caption2.weight(.bold))
                    Text("+\(wg)")
                    Text("this week")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .foregroundStyle(.green)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var statsSparkline: some View {
        SparklineView(data: chartDailyNew?.data.map(\.count) ?? [])
            .opacity(chartDailyNew == nil ? 0 : 1)
    }

    /// 宽屏一行排布里，大数字和三个小数之间的竖分隔。
    private var statsDivider: some View {
        Rectangle().fill(.secondary.opacity(0.2))
            .frame(width: 2, height: 44)
            .padding(.horizontal, 24)
    }

    /// 三个小数。
    ///
    /// `spread`：竖排时每个占等分宽度（`maxWidth: .infinity`），横排时按内容
    /// 收紧——否则它们会把大数字和曲线挤到屏幕两端，就是改之前那个样子。
    private func statsMiniRow(spread: Bool) -> some View {
        let s = store.summary
        return HStack(spacing: 0) {
            // 三个 tap 行为分别匹配：
            //   24h  → 实际房源列表（最 actionable）
            //   7d   → 7 日趋势 chart + 每日 breakdown
            //   Changes → 状态变化趋势 chart（用户可见的 notification 不包含
            //             status_change 事件，无法重建变化的房源列表）
            miniStat(num: s?.new24h ?? 0, desc: "New · 24h", spread: spread) {
                activeRecentMode = .newPast24h
            }
            Rectangle().fill(.secondary.opacity(0.2)).frame(width: 2, height: 36)
                .padding(.horizontal, 14)
            miniStat(num: s?.new7d ?? 0, desc: "New · 7d", spread: spread) {
                openMiniChart(key: "daily_new",
                              title: "New listings",
                              subtitle: "Last 7 days",
                              days: 7)
            }
            Rectangle().fill(.secondary.opacity(0.2)).frame(width: 2, height: 36)
                .padding(.horizontal, 14)
            miniStat(num: s?.changes24h ?? 0, desc: "Changes", spread: spread) {
                activeRecentMode = .changesPast24h
            }
        }
    }

    private func miniStat(num: Int, desc: String, spread: Bool = true,
                          onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(num)")
                    .font(.system(size: 26, weight: .heavy))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: spread ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 直接读 @State 缓存（在 chartDailyNew / summary 变化时 recompute 一次更新）。
    /// 之前是 computed property，每次 body 重算 .suffix(7).reduce(0)；现在 O(1)。
    private var weekGrowthText: String? { weekGrowthCached }

    // MARK: - Matches section (user only)

    /// `stacked`：右栏那种**又窄又高**的位置。
    ///
    /// 横排版本（数字在左、预览卡横向排开）是照「宽而矮」的整行位置调的，塞进
    /// 一条 ~478pt 的列里会变成三张 116pt 的小卡挤在顶上，下面几百 pt 全空着。
    /// 竖排版本把数字提到上面当标题，预览改成一行一条铺满列宽，正好把列填起来，
    /// 顺带能多显示两条（横排最多 5 条要 1180pt，这里 5 条只要够高）。
    /// `minCardHeight`：分栏时把卡拉到和左栏一样高，底边对齐 Explore 的底边。
    /// 0 表示还没量到（第一帧），那就先按内容高度画。
    private func matchesSection(_ me: MeSummary,
                                availableWidth: CGFloat,
                                stacked: Bool = false,
                                minCardHeight: CGFloat = 0) -> some View {
        let previewCount = stacked
            ? stackedPreviewCount(cardHeight: minCardHeight)
            : matchPreviewCount(for: availableWidth)

        return VStack(spacing: 0) {
            // 分栏时标题收进卡里。
            //
            // 左栏第一块是大数字卡，卡里自带 "TOTAL LISTINGS" 没有外置标题；右栏
            // 要是把 "Your matches" 摆在卡外面，右边那张卡就被压低一个标题的高度,
            // 两栏的卡顶边对不齐——截图上一眼就能看出来。收进卡里之后两边都是
            // 「卡自带标题」，顶边平齐。
            //
            // 单栏时保持原样：那儿它和 "Explore" 是并列的两个区标题，一致。
            if !stacked {
                matchesHeader(me, stacked: false)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }

            VStack(alignment: .leading, spacing: 12) {
                if stacked { matchesHeader(me, stacked: true) }
                matchesBody(me, previewCount: previewCount, stacked: stacked)
                // 拉高之后内容留在顶上，多出来的高度落在这里。
                if stacked { Spacer(minLength: 0) }
            }
            .padding(15)
            // minHeight 而不是 height：内容要是比左栏还高（大字号 / 更多预览），
            // 让它自己长出去，别被切。alignment 顶对齐，多的高度全落在下面。
            .frame(minHeight: stacked && minCardHeight > 0 ? minCardHeight : nil,
                   alignment: .top)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.secondary.opacity(0.12), lineWidth: 1))
            .padding(.horizontal, 20)
            // 分栏时不留底部间距：卡的底边就是这一栏的底边，要和左栏的
            // Explore 底边平齐。
            .padding(.bottom, stacked ? 0 : 26)
        }
    }

    /// `stacked` 时按钮不带数字：标题收进卡里之后，"See all 25" 和它正下方那个
    /// 38pt 的 "25" 挨在一起，同一个数念两遍。
    private func matchesHeader(_ me: MeSummary, stacked: Bool) -> some View {
        HStack {
            HStack(spacing: 4) {
                Text("Your matches")
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.5)
                if me.filterActive {
                    Text("(filtered)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(stacked ? "See all ›" : "See all \(me.matchedTotal)") {
                coord.selectedTab = .browse; coord.selectedBrowseMode = .list
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.blue)
        }
    }

    /// 数字块 + 预览。横排一行排开，竖排数字在上、预览一条一行。
    @ViewBuilder
    private func matchesBody(_ me: MeSummary, previewCount: Int, stacked: Bool) -> some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        layout {
            matchedTotalBlock(me, stacked: stacked)

            if matchedPreviews.isEmpty {
                ForEach(0..<previewCount, id: \.self) { _ in
                    matchPreviewPlaceholder(stacked: stacked)
                }
            } else {
                ForEach(matchedPreviews.prefix(previewCount)) { listing in
                    Button {
                        // push 到 Dashboard 自己的栈，不换 tab——见 listingPath。
                        listingPath.append(.byId(listing.id, titleHint: listing.name))
                    } label: {
                        if stacked {
                            matchPreviewRow(listing)
                        } else {
                            matchPreviewCard(listing)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func matchedTotalBlock(_ me: MeSummary, stacked: Bool) -> some View {
        let total = Text("\(me.matchedTotal)")
            .font(.system(size: 38, weight: .heavy))
            .monospacedDigit()
            .tracking(-1)
        let caption = Text("matched · all available")
            .font(.caption)
            .foregroundStyle(.secondary)

        if stacked {
            // 竖排时数字和说明并排当一条标题，不然 38pt 的数字上面顶一行小字，
            // 下面接着一串等宽预览条，中间那一格看着像漏排了。
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                total
                caption
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                total
                caption
            }
            .frame(minWidth: 80)
        }
    }

    @ViewBuilder
    private func matchPreviewPlaceholder(stacked: Bool) -> some View {
        if stacked {
            // 结构照着 matchPreviewRow 走，数据到位时高度才不会跳。
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("⋯⋯⋯⋯").font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("—").font(.system(size: 15, weight: .bold))
                }
                Text("⋯⋯").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity,
                   minHeight: Self.stackedRowHeight - 28,
                   alignment: .leading)
            .padding(.vertical, 14).padding(.horizontal, 16)
            .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("—").font(.system(size: 13, weight: .bold))
                ForEach(0..<5, id: \.self) { _ in
                    Text("⋯⋯").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .padding(.vertical, 12).padding(.horizontal, 10)
            .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// 竖排用的一条预览。
    ///
    /// **房源名是第一行**。横排那张 ~116pt 宽的小卡放不下名字，只能拿价格当标识；
    /// 这里列宽有 ~450pt，不放名字的话五条长得一模一样（价格 + Book + 面积），
    /// 根本认不出哪套是哪套——第一版就是这样，截图上五条只剩数字。
    ///
    /// 两行：名字 + 价格一行，状态 + 面积 / 地点一行。
    private func matchPreviewRow(_ listing: Listing) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(listing.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(listing.priceRaw ?? "—")
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(matchStatusColor(listing))
                        .frame(width: 6, height: 6)
                    Text(matchStatusLabel(listing))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(matchStatusColor(listing))
                        .lineLimit(1)
                    if let detail = matchRowDetail(listing) {
                        Text("· \(detail)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    // 起租日。横排那张小卡一直有（副信息最后一行），摊平成一行时
                    // 被漏掉了——它和价格一样是决定"要不要点进去"的字段，不能省。
                    // 靠右单独放，不混进左边那串副信息里。
                    if let from = listing.availableShortText {
                        Text(from)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity,
               minHeight: Self.stackedRowHeight - 28,
               alignment: .leading)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 状态后面那串副信息：面积 · 地点。
    ///
    /// 地点走 `PlaceSummary`——名字已经在上一行了，楼栋和城市里跟名字重复的词
    /// 要去掉，否则 "OurCampus Diemen #3250" 后面再跟一句 "OurCampus Diemen"。
    /// 去重之后可能什么都不剩，那就只剩面积；面积也没有就整段不显示。
    private func matchRowDetail(_ listing: Listing) -> String? {
        var parts: [String] = []
        if let area = matchAreaText(listing) { parts.append(area) }
        // buildingText 是 String?、city 是 String——compactMap 抹平，顺手去空串
        // （PlaceSummary 只负责去重，不负责去空）。
        if let place = PlaceSummary.text(
            name: listing.name,
            parts: [listing.buildingText, listing.city]
                .compactMap { $0 }.filter { !$0.isEmpty }) {
            parts.append(place)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 竖排一条预览的标称高度（含上下内边距）和条间距。
    /// ``stackedPreviewCount(cardHeight:)`` 按这两个数反推能放几条，所以它们和
    /// ``matchPreviewRow(_:)`` / ``matchesBody`` 里的实际值必须是同一个。
    private static let stackedRowHeight: CGFloat = 78
    private static let stackedRowSpacing: CGFloat = 10

    /// 卡里除预览条以外吃掉的高度：上下内边距 30 + 标题 28 + 间距 12
    /// + 数字块 46 + 数字块到第一条的间距 10。
    private static let stackedChromeHeight: CGFloat = 126

    /// 最多显示几条——不能超过 ``fetchMatchedPreviews()`` 拉回来的条数。
    private static let maxMatchedPreviews = 12

    /// 竖排时按卡高反推能放下几条。
    ///
    /// 卡是被拉到左栏那么高的，高度是已知的，所以条数不该写死：11 寸横屏能放
    /// 9 条，写死 5 条就白扔三百多 pt。
    ///
    /// 用标称行高算，不量实际高度——量的话「条数 → 卡高 → 条数」会绕成一个环。
    /// 代价是大字号下实际行高会超过标称值，卡片跟着长出左栏一点；卡用的是
    /// `minHeight` 不是 `height`，长得出去，不会被切。
    private func stackedPreviewCount(cardHeight: CGFloat) -> Int {
        guard cardHeight > 0 else { return 5 }   // 还没量到，先按老数量画一帧
        let forRows = cardHeight - Self.stackedChromeHeight + Self.stackedRowSpacing
        let fits = Int(forRows / (Self.stackedRowHeight + Self.stackedRowSpacing))
        return min(max(fits, 3), Self.maxMatchedPreviews)
    }

    private func matchPreviewCount(for width: CGFloat) -> Int {
        if width >= 1_180 { return 5 }
        if width >= 940 { return 4 }
        return 3
    }

    // MARK: - Match preview card

    /// 一张 ~80pt 高的迷你卡，挂在 Your matches 区下方 3 列。
    /// 露价格 / 状态点 / 城市+面积，比之前两行（仅 price + city）多一档信息。
    private func matchPreviewCard(_ listing: Listing) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(listing.priceRaw ?? "—")
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            HStack(spacing: 4) {
                Circle()
                    .fill(matchStatusColor(listing))
                    .frame(width: 5, height: 5)
                Text(matchStatusLabel(listing))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(matchStatusColor(listing))
                    .lineLimit(1)
            }

            // 副信息层：面积 → 楼栋 → 城市 → 起租日，每行独占一条，10pt 副字号
            if let area = matchAreaText(listing) {
                Text(area)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let building = listing.buildingText {
                Text(building)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !listing.city.isEmpty {
                Text(listing.city)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let from = listing.availableShortText {
                // 不加 "from" 前缀 —— 用户希望窄卡里直接显示"Jun 22"，少噪声
                Text(from)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .padding(.vertical, 12).padding(.horizontal, 10)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func matchStatusLabel(_ listing: Listing) -> String {
        switch listing.statusKind {
        case .book: return "Book"
        case .lottery: return "Lottery"
        case .reserved: return "Reserved"
        case .other: return listing.status
        }
    }

    private func matchStatusColor(_ listing: Listing) -> Color {
        switch listing.statusKind {
        case .book:             return .statusBook
        case .lottery:          return .statusLottery
        case .reserved, .other: return .statusOccupied
        }
    }

    /// 直接 forward 到 `Listing.normalizedAreaText`（已在模型层缓存归一逻辑）。
    /// 之前每张匹配卡每次 render 都 trim + lowercased 一遍。
    private func matchAreaText(_ listing: Listing) -> String? {
        listing.normalizedAreaText
    }

    // MARK: - Explore section

    /// Explore 区的列数。
    ///
    /// 原本写死两列。iPhone 上对，iPad 横屏（内容宽 ~1150pt）上就是两根 570pt
    /// 宽的柱子——卡高固定 116pt，越宽越像被拉长的横条。六张卡，3×2 比 2×3 更
    /// 匀称，也比 6×1 留得住每张卡里那三列统计的可读宽度。
    private func exploreColumns(for width: CGFloat) -> Int {
        if width >= 1_000 { return 3 }
        return 2
    }

    /// Explore 卡的高度。
    ///
    /// 按**列宽**算而不是屏宽——iPad 竖屏 834pt 是 2 列，每张 ~392pt，比横屏
    /// 3 列的 ~378pt 还宽。只看屏宽会漏掉竖屏那一档，而它恰恰是最扁的。
    ///
    /// 不按比例硬撑：卡里那条 6pt 进度条加一行统计是固定高度，多出来的高度会
    /// 落在 header 与 content 之间的 Spacer 上（见 exploreCard 的注释：所有
    /// chart 视觉落在卡下半部同一条带）。撑太高只会把中间那段空白拉长，所以
    /// 分档抬，不连续缩放。
    /// 卡里图形的缩放系数。
    ///
    /// 六张卡里的图形尺寸（堆叠条 6pt、竖条最高 36pt、横条 5pt）都是照着 116pt
    /// 那一档调死的。卡长高之后它们不跟着长，多出来的高度全落进 header 与
    /// content 之间的 Spacer——结果就是标题和图之间一大片空白，卡看着更空而不是
    /// 更充实。按卡高等比放大，让多出来的高度回到图上。
    private func chartScale(for height: CGFloat) -> CGFloat { height / 116 }

    private func exploreCardHeight(for width: CGFloat) -> CGFloat {
        let columns = CGFloat(exploreColumns(for: width))
        let columnWidth = (width - 40 - 10 * (columns - 1)) / columns
        if columnWidth >= 300 { return 170 }
        if columnWidth >= 230 { return 140 }
        return 116
    }

    /// `showsMore`：带不带底下那条 "More breakdowns ›"。
    /// 分栏时按钮由 ``dashboardBody(_:)`` 单独排在被测高的区块外面，见那里的注释。
    private func exploreSection(availableWidth: CGFloat,
                                showsMore: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Explore")
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.5)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                     count: exploreColumns(for: availableWidth)),
                      spacing: 10) {
                let h = exploreCardHeight(for: availableWidth)
                sourceMiniCard(height: h)
                statusMiniCard(height: h)
                priceMiniCard(height: h)
                typeMiniCard(height: h)
                energyMiniCard(height: h)
                tenantMiniCard(height: h)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, showsMore ? 18 : 0)

            if showsMore {
                exploreMoreButton
            }
        }
    }

    private var exploreMoreButton: some View {
        Button {
            coord.selectedTab = .browse; coord.selectedBrowseMode = .list
        } label: {
            Text("More breakdowns ›")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Mini cards
    //
    // 共用骨架（exploreCard）保证所有 Explore 卡：
    //   - 标题永远在最上 14pt padding 处对齐，chevron 用小一号 11pt semibold
    //     替代之前 18pt light，少抢戏；
    //   - header 和 content 之间 Spacer(minLength:) 强行拉开，所有 chart 视觉
    //     落在卡下半部同一条带；
    //   - 卡高 88 → 116，给 byStatus 的 3 个 mono 统计列、byType 的 3 行
    //     水平条留呼吸空间，不再"太满"。

    @ViewBuilder
    private func exploreCard<Content: View>(
        title: String,
        tapKey: String,
        tapTitle: String,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            openMiniChart(key: tapKey, title: tapTitle)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(title)
                        .font(.system(size: 13, weight: .heavy))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 10)
                content()
            }
            .padding(14)
            .frame(height: height)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.1), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func statusMiniCard(height: CGFloat) -> some View {
        exploreCard(title: "By status", tapKey: "status_dist", tapTitle: "By Status", height: height) {
            if !statusBuckets.isEmpty {
                // statusBuckets 是 [available, lottery, unavailable] 三元，
                // 由 recomputeDerivedCharts() 在 chartStatus 变化时算一次。
                let available   = statusBuckets[0].count
                let lottery     = statusBuckets[1].count
                let unavailable = statusBuckets[2].count
                let sum = max(available + lottery + unavailable, 1)

                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { proxy in
                        let w = proxy.size.width
                        HStack(spacing: 0) {
                            if available > 0 {
                                RoundedRectangle(cornerRadius: 2).fill(Color.statusBook)
                                    .frame(width: max(4, w * CGFloat(available) / CGFloat(sum)))
                            }
                            if lottery > 0 {
                                RoundedRectangle(cornerRadius: 2).fill(Color.statusLottery)
                                    .frame(width: max(4, w * CGFloat(lottery) / CGFloat(sum)))
                            }
                            if unavailable > 0 {
                                RoundedRectangle(cornerRadius: 2).fill(Color.statusOccupied.opacity(0.4))
                                    .frame(width: max(4, w * CGFloat(unavailable) / CGFloat(sum)))
                            }
                        }
                    }
                    .frame(height: 6 * chartScale(for: height)).clipShape(Capsule())

                    HStack(alignment: .firstTextBaseline) {
                        VStack(spacing: 2) {
                            Text("\(available)").fontWeight(.bold).foregroundStyle(Color.statusBook)
                            Text("book").foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(spacing: 2) {
                            Text("\(lottery)").fontWeight(.bold).foregroundStyle(Color.statusLottery)
                            Text("lottery").foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(spacing: 2) {
                            Text("\(unavailable)").fontWeight(.bold).foregroundStyle(Color.statusOccupied)
                            Text("other").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }

    private func sourceMiniCard(height: CGFloat) -> some View {
        exploreCard(title: "By platform", tapKey: "source_dist", tapTitle: "By Platform", height: height) {
            if !sourceBuckets.isEmpty {
                let total = max(sourceBuckets.reduce(0) { $0 + $1.count }, 1)
                // 颜色按**平台**取，不再按下标取模。三个平台时 palette[idx % 3]
                // 够用，接到七个之后颜色开始重复：堆叠条上相邻两段可能同色，
                // 图例和条形也对不上号。见 Platform.color。
                let shown = sourceBuckets.prefix(3)
                let hidden = sourceBuckets.count - shown.count
                VStack(alignment: .leading, spacing: 8) {
                    GeometryReader { proxy in
                        let w = proxy.size.width
                        HStack(spacing: 0) {
                            ForEach(sourceBuckets) { entry in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Platform.color(entry.label))
                                    .frame(width: max(4, w * CGFloat(entry.count) / CGFloat(total)))
                            }
                        }
                    }
                    .frame(height: 6 * chartScale(for: height))
                    .clipShape(Capsule())

                    HStack {
                        ForEach(shown) { entry in
                            VStack(spacing: 2) {
                                Text("\(entry.count)")
                                    .fontWeight(.bold)
                                    .foregroundStyle(Platform.color(entry.label))
                                Text(entry.label)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity)
                        }
                        // 卡片只放得下三列，但不能让另外几个平台**无声消失**——
                        // 用户会以为只有三家。点开卡片有完整图表。
                        if hidden > 0 {
                            VStack(spacing: 2) {
                                Text("+\(hidden)")
                                    .fontWeight(.bold)
                                    .foregroundStyle(.secondary)
                                Text("more")
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func priceMiniCard(height: CGFloat) -> some View {
        exploreCard(title: "By price", tapKey: "price_dist", tapTitle: "By Price", height: height) {
            if !priceSortedAsc.isEmpty {
                let sorted = priceSortedAsc   // cached
                let maxCount = sorted.map(\.count).max() ?? 1

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(sorted.prefix(9)) { entry in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.blue.opacity(0.55))
                                .frame(height: max(4, ratio(entry.count, maxCount) * 36 * chartScale(for: height)))
                        }
                    }
                    HStack {
                        Text(sorted.first?.label ?? "€—").foregroundStyle(.secondary)
                        Spacer()
                        Text(sorted.last?.label ?? "€—").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func typeMiniCard(height: CGFloat) -> some View {
        exploreCard(title: "By type", tapKey: "type_dist", tapTitle: "By Type", height: height) {
            if !typeTopThree.isEmpty {
                let merged = typeTopThree   // cached top-3 (bucketed + sorted)
                let maxCount = merged.map(\.count).max() ?? 1

                VStack(spacing: 5) {
                    ForEach(Array(merged)) { entry in
                        HStack(spacing: 6) {
                            Text(entry.label)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .frame(width: 44, alignment: .leading)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.blue.opacity(0.6))
                                    .frame(width: proxy.size.width * ratio(entry.count, maxCount))
                            }
                            .frame(height: 5 * chartScale(for: height))
                            Text("\(entry.count)")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 26, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func energyMiniCard(height: CGFloat) -> some View {
        exploreCard(title: "By energy", tapKey: "energy_dist", tapTitle: "By Energy", height: height) {
            if !energyMerged.isEmpty {
                let merged = energyMerged   // cached
                let maxCount = merged.map(\.count).max() ?? 1

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(merged) { entry in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(energyBarColor(entry.label))
                                .frame(maxWidth: .infinity)
                                .frame(height: max(4, ratio(entry.count, maxCount) * 32 * chartScale(for: height)))
                        }
                    }
                    HStack(spacing: 4) {
                        ForEach(merged.prefix(5)) { entry in
                            Text(entry.label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func tenantMiniCard(height: CGFloat) -> some View {
        exploreCard(title: "By tenant", tapKey: "tenant_dist", tapTitle: "By Tenant", height: height) {
            if !tenantTopThree.isEmpty {
                let maxCount = tenantTopThree.map(\.count).max() ?? 1

                VStack(spacing: 5) {
                    ForEach(tenantTopThree) { entry in
                        HStack(spacing: 6) {
                            Text(tenantMiniLabel(entry.label))
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .frame(width: 54, alignment: .leading)
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(.blue.opacity(0.6))
                                    .frame(width: proxy.size.width * ratio(entry.count, maxCount))
                            }
                            .frame(height: 5 * chartScale(for: height))
                            Text("\(entry.count)")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 24, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }


    // MARK: - Error

    @ViewBuilder
    private func errorView(_ err: String) -> some View {
        let apiErr = store.lastError
        ContentUnavailableView {
            Label(apiErr?.errorDescription ?? "Unable to Load",
                  systemImage: apiErr?.systemImage ?? "wifi.slash")
        } description: { Text(err) } actions: {
            Button("Try Again") { Task { await refresh() } }
        }
    }

    // MARK: - Helpers

    private func ratio(_ value: Int, _ maxVal: Int) -> CGFloat {
        guard maxVal > 0 else { return 0 }
        let r = CGFloat(value) / CGFloat(maxVal)
        return r < 0.04 ? 0.04 : r
    }

    private func energyRank(_ label: String) -> Int {
        let labels = ["A+++", "A++", "A+", "A", "B", "C", "D", "E", "F"]
        return labels.firstIndex(of: label.uppercased().trimmingCharacters(in: .whitespaces)) ?? 99
    }

    private func priceSortKey(_ label: String) -> Double {
        // Parse numeric lower bound from strings like "€0-500", "500-1000", "€1,200+"
        let cleaned = label.replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let dashIdx = cleaned.firstIndex(of: "-") {
            return Double(cleaned[..<dashIdx].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return Double(cleaned.replacingOccurrences(of: "+", with: "")) ?? 0
    }

    private func openMiniChart(key: String, title: String,
                               subtitle: String? = nil, days: Int = 30) {
        activeChart = ChartDetail(key: key, title: title, subtitle: subtitle, days: days)
    }

    private func energyBarColor(_ label: String) -> Color {
        // 桶后标签是 "A+" / "A" / "B" / "C" / "D" / ... — rank 表里:
        //   A+++=0, A++=1, A+=2, A=3, B=4, C=5, D=6, E=7, F=8
        // 让 A+ 单独绿色，A 用 mint 跟它视觉拉开档次。
        // 三个绿色等级用 Asset Catalog 语义 token（有亮/暗双值，之前硬编码
        // RGB 在暗模式下不会自适应）；B/C/D 用 SwiftUI 系统色（已自适应）。
        switch energyRank(label) {
        case 0...1: return .energyTop      // A+++ / A++
        case 2:     return .energyAPlus    // A+
        case 3:     return .energyA        // A
        case 4:     return .yellow         // B
        case 5:     return .orange         // C
        default:    return .red            // D 及以下
        }
    }

    private func tenantMiniLabel(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("student") { return "Student" }
        if lower.contains("working") || lower.contains("employed") { return "Working" }
        if lower.contains("young") { return "Young" }
        if lower.contains("any") || lower.contains("all") { return "Any" }
        return label
            .components(separatedBy: CharacterSet(charactersIn: "(_-"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized ?? label
    }

    private func refresh() async {
        // 防御：SwiftUI 的 .refreshable / .task 在 @Observable 状态变化时可能把
        // 当前任务 cancel 掉（之前的 bug：SSE 推一批通知时整个 dashboard 的 refresh
        // 任务被 cancel，所有 URLSession.data 同步抛 NSURLErrorCancelled -999）。
        //
        // Task { ... } 是非结构化任务，**不继承父任务的 cancellation**。即便父任务
        // (.refreshable) 被 cancel，里面的 URLSession 请求也会正常跑完、状态正常更新。
        let work = Task { @MainActor in
            await store.fetchSummary()
            if auth.isUser {
                await store.fetchMeSummary()
                await fetchMatchedPreviews()
            }
            await fetchMiniCharts()
        }
        // 等结果完成；work 不继承父任务 cancellation，因此即使 .refreshable
        // 被取消，里面的数据请求仍会继续跑完。
        await work.value
    }

    private func fetchMatchedPreviews() async {
        do {
            // 竖排右栏最多能显示 maxMatchedPreviews 条，拉够那么多。横排用不到
            // 这么多（最宽也只显示 5 条），多出来的只是没画，不影响。
            let resp = try await APIClient.shared.getListings(
                limit: Self.maxMatchedPreviews, offset: 0)
            matchedPreviews = resp.items
        } catch {
            matchedPreviews = []
        }
    }

    private func fetchMiniCharts() async {
        // 分 3 批发出，每批 2-3 个请求，避免 7 并发同时打到后端造成 TCP 队头阻塞。
        // 第一批是最重要的 3 张（首页 sparkline + source/status mini card），
        // 第二批和第三批是详情页才展开的分布图，优先级靠后。

        // Batch 1: daily_new + source_dist + status_dist
        async let dn = try? APIClient.shared.getPublicChart(key: "daily_new", days: 7)
        async let so = try? APIClient.shared.getPublicChart(key: "source_dist", days: 30)
        async let st = try? APIClient.shared.getPublicChart(key: "status_dist", days: 30)
        let (dnR, soR, stR) = await (dn, so, st)

        // Batch 2: price_dist + type_dist
        async let pr = try? APIClient.shared.getPublicChart(key: "price_dist", days: 30)
        async let tp = try? APIClient.shared.getPublicChart(key: "type_dist", days: 30)
        let (prR, tpR) = await (pr, tp)

        // Batch 3: energy_dist + tenant_dist
        async let en = try? APIClient.shared.getPublicChart(key: "energy_dist", days: 30)
        async let tn = try? APIClient.shared.getPublicChart(key: "tenant_dist", days: 30)
        let (enR, tnR) = await (en, tn)

        chartDailyNew = dnR
        chartSource = soR
        chartStatus = stR
        chartPrice = prR
        chartType = tpR
        chartEnergy = enR
        chartTenant = tnR
        recomputeDerivedCharts()
    }

    /// 把 mini chart 用到的派生数据（排序/分桶/求和）一次性算完并缓存到 @State，
    /// 让 view body 直接 O(1) 读取，避免每次 invalidation 重算。
    private func recomputeDerivedCharts() {
        // Status: 拆成 [available, lottery, unavailable] 三元
        if let chart = chartSource, !chart.data.isEmpty {
            sourceBuckets = chart.data.bucketed(forKey: "source_dist")
        } else {
            sourceBuckets = []
        }

        // Status: 拆成 [available, lottery, unavailable] 三元
        if let chart = chartStatus, !chart.data.isEmpty {
            let total = chart.data.reduce(0) { $0 + $1.count }
            let available = chart.data.first(where: { $0.label.lowercased().contains("available") })?.count ?? 0
            let lottery   = chart.data.first(where: { $0.label.lowercased().contains("lottery") })?.count ?? 0
            statusBuckets = [
                ChartEntry(label: "available",   count: available),
                ChartEntry(label: "lottery",     count: lottery),
                ChartEntry(label: "unavailable", count: total - available - lottery),
            ]
            statusBucketsTotal = total
        } else {
            statusBuckets = []
            statusBucketsTotal = 0
        }

        // Price: 升序排好
        if let chart = chartPrice, !chart.data.isEmpty {
            priceSortedAsc = chart.data.sorted {
                priceSortKey($0.label) < priceSortKey($1.label)
            }
        } else {
            priceSortedAsc = []
        }

        // Type: bucketed("Apt"/"Studio"/"Loft") + 取 top 3
        if let chart = chartType, !chart.data.isEmpty {
            typeTopThree = Array(
                chart.data.bucketed(forKey: "type_dist")
                    .sorted { $0.count > $1.count }
                    .prefix(3)
            )
        } else {
            typeTopThree = []
        }

        // Energy: bucketed (A+/A/B/...)
        if let chart = chartEnergy, !chart.data.isEmpty {
            energyMerged = chart.data.bucketed(forKey: "energy_dist")
        } else {
            energyMerged = []
        }

        // Tenant requirements: top 3 by count
        if let chart = chartTenant, !chart.data.isEmpty {
            tenantTopThree = Array(chart.data.sorted { $0.count > $1.count }.prefix(3))
        } else {
            tenantTopThree = []
        }

        // Week growth: 最近 7 天 daily_new 累加
        if let daily = chartDailyNew {
            let last7 = daily.data.suffix(7).reduce(0) { $0 + $1.count }
            weekGrowthCached = last7 > 0 ? "\(last7)" : nil
        } else if let s = store.summary {
            weekGrowthCached = "\(s.new7d)"
        } else {
            weekGrowthCached = nil
        }
    }

    private func relativeTime(_ iso: String) -> String {
        ServerTime.relativeTime(iso)
    }
}

// MARK: - Recent activity sheet

/// 暂时只剩 "新房 24h" 一种 sheet ——7d 和 Changes 改成走 ChartDetailView 趋势图。
enum RecentActivityMode: String, Identifiable {
    case newPast24h
    case changesPast24h
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newPast24h:      return "New · last 24h"
        case .changesPast24h:  return "Changes · last 24h"
        }
    }

    var maxAge: TimeInterval {
        switch self {
        case .newPast24h:      return 24 * 3600
        case .changesPast24h:  return 24 * 3600
        }
    }
}

/// 拉一页 listings（后端会按用户角色自动套用 user filter），客户端按
/// `firstSeen` 时间窗筛掉旧的，剩下的就是"24h 内新增 + 符合用户过滤条件的房源"。
/// 用 ListingRow 渲染，跟 Browse 页样式一致。
struct RecentActivitySheet: View {
    let mode: RecentActivityMode
    @Environment(NavigationCoordinator.self) private var coord
    @Environment(\.dismiss) private var dismiss

    @State private var listings: [Listing] = []
    @State private var changes: [NotificationItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var filtered: [Listing] = []

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && listings.isEmpty && changes.isEmpty {
                    ProgressView().padding(.top, 60).frame(maxWidth: .infinity)
                } else if let err = errorMessage, listings.isEmpty && changes.isEmpty {
                    ContentUnavailableView("Unable to Load",
                                           systemImage: "wifi.slash",
                                           description: Text(err))
                } else if mode == .changesPast24h {
                    if changes.isEmpty {
                        ContentUnavailableView("No changes", systemImage: "arrow.left.arrow.right",
                            description: Text("No status changes in the last 24 hours."))
                    } else {
                        List {
                            Section {
                                ForEach(changes) { n in
                                    Button {
                                        guard !n.listingID.isEmpty else { return }
                                        dismiss()
                                        coord.openListing(id: n.listingID)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(n.listingTitleHint)
                                                .font(.system(size: 14, weight: .medium))
                                            Text(n.body)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                Text("\(changes.count) status changes")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .tracking(0.7)
                                    .foregroundStyle(.secondary)
                                    .textCase(nil)
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView(
                        "No new listings",
                        systemImage: "house",
                        description: Text("No listings matched your filter in the last 24 hours."))
                } else {
                    List {
                        Section {
                            ForEach(filtered) { listing in
                                Button {
                                    dismiss()
                                    coord.openListing(id: listing.id)
                                } label: {
                                    ListingRow(listing: listing)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("\(filtered.count) \(filtered.count == 1 ? "listing" : "listings") · matches your filter")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .tracking(0.7)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .task { await fetch() }
            .refreshable { await fetch() }
            .onChange(of: listings) { _, _ in recomputeFiltered() }
        }
    }

    private func recomputeFiltered() {
        let cutoff = Date().addingTimeInterval(-mode.maxAge)
        filtered = listings
            .filter { ($0.firstSeenDate ?? .distantPast) >= cutoff }
            .sorted { ($0.firstSeenDate ?? .distantPast) > ($1.firstSeenDate ?? .distantPast) }
    }

    @MainActor
    private func fetch() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            if mode == .changesPast24h {
                let resp = try await APIClient.shared.getNotifications(limit: 100, offset: 0)
                let cutoff = Date().addingTimeInterval(-mode.maxAge)
                changes = resp.items.filter { n in
                    n.type == "status_change" && (n.createdDate ?? .distantPast) >= cutoff
                }
            } else {
                let resp = try await APIClient.shared.getListings(limit: 100, offset: 0)
                listings = resp.items
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Press scale modifier

/// 轻量按压反馈：touch down 缩放到 0.97，松手回弹到 1.0。
/// 用于非 Button 的可点击元素（onTapGesture / contentShape + onTap）。
/// Button 场景请用 ``ScaleButtonStyle``（通过 configuration.isPressed 驱动，无手势冲突）。
struct PressScaleModifier: ViewModifier {
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.97 : 1.0)
            .animation(.spring(duration: 0.18), value: pressed)
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 44,
                                pressing: { pressing in
                if pressed != pressing {
                    pressed = pressing
                }
            }, perform: {})
    }
}

/// 按钮场景的按压缩放样式：用 configuration.isPressed 驱动，无手势冲突。
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}

// MARK: - Sparkline

/// 迷你趋势线。
///
/// 原来是直线段相连——七个点、130pt 宽，每个折角都很扎眼，读起来像锯齿而不像
/// 趋势。改成 Catmull-Rom 插值出的三次贝塞尔：点还是那些点，只是拐弯变圆。
///
/// `closed` 用来复用同一条曲线画填充：曲线本身必须两处完全一致，各画一遍迟早
/// 分叉，填充和描边就会错开一条缝。
// `nonisolated`：`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 会把这个类型也放到
// 主 actor 上，而 `Shape.path(in:)` 是 nonisolated 的要求——Xcode 27 起这条
// 不匹配从警告升级成错误（#ConformanceIsolation）。路径计算是纯函数，不碰任何
// 状态，显式退出隔离即可。同 ChartData / MapClustering 那一批。
private nonisolated struct Sparkline: Shape {
    let data: [Int]
    var closed: Bool = false

    func path(in rect: CGRect) -> Path {
        Path { p in
            guard data.count > 1, let hi = data.max(), let lo = data.min() else { return }

            // 纵向按 **min–max** 归一，不是从 0 算起。
            //
            // 原先是 y = h - v * (h / max)：数据落在 40–80 时，最小的那一点也在
            // y ≈ 0.5h，整条线被压在上半部，下面一半永远空着——看着就是"曲线偏上"。
            //
            // 迷你趋势线没有坐标轴，本来就只表达**形状**，不表达绝对量级；量级由
            // 旁边那个大数字负责。上下各留一点余量，免得线宽把峰谷削平。
            let inset: CGFloat = 4
            let usable = max(rect.height - inset * 2, 1)
            let span = CGFloat(hi - lo)
            let stepX = rect.width / CGFloat(data.count - 1)
            let pts = data.indices.map { i -> CGPoint in
                // 全平时（span == 0）画在正中，而不是除零。
                let t = span > 0 ? CGFloat(data[i] - lo) / span : 0.5
                return CGPoint(x: CGFloat(i) * stepX,
                               y: inset + (1 - t) * usable)
            }

            p.move(to: pts[0])
            for i in 0..<(pts.count - 1) {
                // Catmull-Rom → 三次贝塞尔。端点各自复用自己，避免越界。
                let p0 = pts[max(i - 1, 0)]
                let p1 = pts[i]
                let p2 = pts[i + 1]
                let p3 = pts[min(i + 2, pts.count - 1)]
                // 控制点的 y 夹回画布内：Catmull-Rom 在相邻值落差大时会冲出
                // 上下沿，迷你图上表现为曲线被裁掉一截。
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6,
                                 y: min(max(p1.y + (p2.y - p0.y) / 6, inset),
                                        rect.height - inset))
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6,
                                 y: min(max(p2.y - (p3.y - p1.y) / 6, inset),
                                        rect.height - inset))
                p.addCurve(to: p2, control1: c1, control2: c2)
            }

            if closed {
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: 0, y: rect.maxY))
                p.closeSubpath()
            }
        }
    }
}

/// 曲线 + 底部渐变。
///
/// 只有一根线时它读起来像"一条线"；加上向下淡出的填充才读起来像"一段趋势"。
private struct SparklineView: View {
    let data: [Int]
    var tint: Color = .blue

    var body: some View {
        ZStack {
            Sparkline(data: data, closed: true)
                .fill(LinearGradient(
                    colors: [tint.opacity(0.28), tint.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom))
            Sparkline(data: data)
                // 圆头圆角：折线的尖角正是"丑"的来源，端点也一并磨圆。
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5,
                                                 lineCap: .round, lineJoin: .round))
        }
    }
}
