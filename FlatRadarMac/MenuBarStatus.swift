import SwiftUI
import AppKit
import FlatRadarCore

/// 菜单栏常驻的存储键和文案口径。
///
/// 单独一个命名空间是因为这条设置有**三个**读者：`FlatRadarMacApp`（决定
/// `MenuBarExtra` 场景在不在）、`GeneralSettings`（那个开关）、``AppFeed``
/// （决定没窗口时 SSE 断不断）。三处各写一遍字符串迟早会打错一个。
nonisolated enum MenuBarResidency {
    static let storageKey = "menuBarResident"

    /// 默认**开**。
    ///
    /// 原先是关的，理由写在这儿：「菜单栏图标是用户的地盘，不是应用可以默认占的」。
    /// 那条理由是**对着上一版的面板**说的——那时候点开只有三行字（一个匹配数、
    /// 一句扫描时间），占一格菜单栏换不来什么，让用户自己去设置页开才合理。
    ///
    /// 现在那一格是设计稿 t5 那整块：今日新增 + 趋势 + 当前筛选 + 五条可点的最新
    /// 房源。这个 app 的用途就是"不打开它也知道有没有新房"，而这是**唯一**在
    /// 没有窗口时还能提供它的形态。默认关等于默认把主要用途藏在设置页第二个开关
    /// 后面。
    ///
    /// ⚠️ 代价没有变，只是换了谁来承担：开着就等于「没有内容窗口也维持 SSE」
    /// （风险 6）。也就是说**装完就有一条常驻的后台连接**，而不再是用户自己按下的。
    /// 关掉它的地方还在原处（设置 → General），关掉之后流也跟着断——
    /// ``AppFeed/wantsStream(authenticated:isGuest:contentWindows:menuBarResident:)``
    /// 那条规则一个字都没动。
    static let defaultOn = true
}

// MARK: - 面板要画的那份数据

/// 面板上的每一个数，**算好之后**的样子。
///
/// 为什么在视图外面单独立一个值
/// --------------------------
/// 这一屏的问题几乎全是**画出来才看得见**的那一类：标题在 360 宽里第几个词
/// 截断、空数据时会不会留一截空白、深色下哪一块塌进背景。小组件那一轮为此
/// 抓到八处，没有一处是读代码能发现的。
///
/// 视图直接读 ``AppFeed`` 的话，要画它就得有网络、有登录、有后端；换成一个
/// 纯值，`ImageRenderer` 就能把每一种状态离线渲染出来看
/// （`MenuBarPanelRenderTests`）。这和小组件从 `WidgetSnapshot` 画是同一个形状，
/// 那边正是这么把问题一个个看出来的。
///
/// 顺带把「怎么从 feed 算出这些」和「怎么摆」分开了：前者可测，后者可看。
struct MenuBarPanel: Equatable {

    /// NEWEST 那一段的一行。
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let price: String
        let age: String
        let status: ListingStatus
    }

    /// 今日新增。`nil` = 还没拿到，画成 `—`。
    var newToday: Int?

    /// 相对基准的涨跌。样本不足 3 天时是 `nil`，整段不画。
    var changeVsBaseline: Int?

    /// 每日新增序列，旧 → 新。
    var series: [Int] = []

    /// 后端上次扫描是多久以前（`4m ago`）。`nil` = 这条信息没拿到。
    var scannedAgo: String?

    /// 上一次 `/stats/public/summary` 失败了。页眉那颗点据此变橙。
    var offline = false

    /// 当前 `listing_filter` 的人话版本。`nil` = 访客，整行收起。
    var filterSummary: String?

    /// 未读数。0 或访客时不画那枚胶囊。
    var unread = 0

    /// NEWEST 那几行。空数组时连标题一起收走。
    var rows: [Row] = []

    /// 下一个有货可抢的入住日。`nil` = 没有日历数据，整条横幅不画。
    var nextMoveIn: (date: Date, days: Int)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.newToday == rhs.newToday
            && lhs.changeVsBaseline == rhs.changeVsBaseline
            && lhs.series == rhs.series
            && lhs.scannedAgo == rhs.scannedAgo
            && lhs.offline == rhs.offline
            && lhs.filterSummary == rhs.filterSummary
            && lhs.unread == rhs.unread
            && lhs.rows == rhs.rows
            && lhs.nextMoveIn?.date == rhs.nextMoveIn?.date
            && lhs.nextMoveIn?.days == rhs.nextMoveIn?.days
    }
}

// MARK: - 面板

/// 菜单栏那一格的内容。设计稿 `FlatRadar Mac - Menu bar.dc.html` 的 t5。
///
/// 稿子那句话定了这一屏的性质：**「面板是小组件的可操作版本」**——同样的数字
/// 锚点、同样的趋势条，但下面的列表是可点的，底部是跳主窗口的入口。所以数字
/// 全部走和小组件同一份口径函数（``StatusWording`` / ``DailyNew``），只有交互
/// 是这里独有的。
///
/// 稿子那条琥珀色横幅换了内容
/// ------------------------
/// 稿子在 NEWEST 和底部菜单之间画的是 `Lottery closes · Kastanjelaan 400 · in 2d`。
/// **没有这个数据**：`Listing` 上和时间有关的只有 `availableFrom` / `firstSeen` /
/// `lastSeen`，`lottery` 是个**状态**（"Available in lottery"），不带截止时间；
/// openapi 里 `deadline` / `closes` / `draw_at` 各出现 0 次。
///
/// 换成**下一个有货可抢的入住日**——和小组件大号那条横幅是同一个替换、同一句
/// 文案（``StatusWording/nextMoveInOn(_:)``）、同一个颜色。形状照抄稿子：
/// 圆点 + 一句话 + 右端一个相对时间，换的只是里面放的那个日期。
/// 没有日历数据时整条不画，而不是画一条空的。
struct MenuBarPanelView: View {

    let panel: MenuBarPanel
    var refreshing = false

    var onRefresh: () -> Void = {}
    var onOpenRow: (MenuBarPanel.Row) -> Void = { _ in }
    var onOpenApp: () -> Void = {}
    var onQuit: () -> Void = {}

    @State private var hoveredRow: String?

    /// 稿子写死的 360。
    ///
    /// 上一版是 260，那是按只有"标签 + 大数字 + 一行时间"量的。现在多了趋势柱、
    /// 筛选行和五行房源，房源那行右边还要摆价格和时间——260 下标题会在第三个词
    /// 就截断。
    static let width: CGFloat = 360

    /// 面板左右两套内缩：贴边的文字用 14，带底色的块用 10。
    ///
    /// 差这 4pt 是有意的：块自己有圆角和填充，它的**视觉**左沿是填充的边，
    /// 再缩到 14 会比上面的标题更靠里，看着像缩进了一级。
    private static let textInset: CGFloat = 14
    private static let bandInset: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            anchor
            filterBand
            newest
            moveInBand
            actions
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: Self.width)
    }

    // MARK: - 页眉

    private var header: some View {
        HStack(spacing: 8) {
            Text("FlatRadar")
                .font(.headline)
            statusDot
            Text(scannedLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            refreshButton
        }
        .padding(.horizontal, Self.textInset)
    }

    /// 那颗点说的是**这次刷新拿到数据了没有**，不是"扫描器活着没有"。
    ///
    /// 稿子把它画在时间前面，最容易的做法是让它跟着"扫描时间够不够新"变色——
    /// 但那需要一个阈值，而扫描器多久跑一趟这件事客户端并不知道（后端没有任何
    /// 接口说它的节奏）。随手定 10 分钟，就会在扫描间隔比它长的任何一天里长期
    /// 显示成灰的，读起来像"坏了"。
    ///
    /// `SummaryModel.failed` 是真实状态：上一次 `/stats/public/summary` 成没成功。
    /// 后端挂了的时候这颗点立刻变橙，而这恰恰是用户打开这个面板最想知道的事。
    /// ⚠️ 还**什么都没取过**的时候这颗点不画。
    ///
    /// `offline` 的初值是 false（`SummaryModel.failed` 一开始就是 false），所以
    /// 第一次刷新完成之前，一颗绿点会和旁边那句 `Last scan time unavailable`
    /// 同时出现——一边说"好着呢"，一边说"不知道"。渲染空状态那张图时一眼就看到了。
    ///
    /// 绿 = 取到了，橙 = 取失败了，**没有** = 还不知道。第三种状态本来就存在，
    /// 就该有第三种画法，而不是挑一个现成的颜色替它说话。
    @ViewBuilder
    private var statusDot: some View {
        if panel.offline {
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
                .accessibilityLabel("Offline")
        } else if panel.scannedAgo != nil {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
                .accessibilityLabel("Online")
        }
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(refreshing)
        .opacity(refreshing ? 0.4 : 1)
        .help("Refresh")
        .accessibilityLabel("Refresh")
    }

    /// ⚠️ 稿子这一行写的是 `synced 1m ago`，这里说的是 **`Scanned`**。
    ///
    /// 因为这个数只有一个来源：``MonitorStatus/lastScrape``，**后端扫描器**上一次
    /// 跑完的时间。`synced` 会被读成「我这台机器上一次同步是 1 分钟前」，而那是
    /// 另一件事——面板一打开就 `refreshShared`，本机的同步时间永远是"刚刚"，
    /// 写出来没有信息量。两件事还会分开失败：后端停摆时前者越来越旧，后者一直是新的。
    ///
    /// 小组件那一格说的也是 `scanned`，同一个数就该是同一个词。
    private var scannedLabel: String {
        guard let ago = panel.scannedAgo else {
            return StatusWording.scanTimeUnavailable
        }
        // 单独成行，首字母提上去。侧栏那处是 `7 platforms · scanned 4m ago`，
        // 跟在别的东西后面，所以那里不套。
        return StatusWording.sentence(StatusWording.scanned(ago))
    }

    // MARK: - 锚点：今日新增 + 趋势柱

    private var anchor: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                SectionHeading(StatusWording.newToday)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(StatusWording.countText(panel.newToday))
                        // 38pt。字阶那条规则（``Theme`` 顶部）说"不写死磅值"，
                        // 展示数字是它自己列出的例外：统计带 44、这里 38——
                        // 面板只有 360 宽，44 会把右边的趋势柱挤掉一大截。
                        .font(.system(size: 38, weight: .semibold, design: .monospaced))
                        .tracking(-1.6)
                        .monospacedDigit()
                    if let pct = panel.changeVsBaseline {
                        Text(StatusWording.percent(pct))
                            .font(.subheadline.weight(.bold))
                            .monospacedDigit()
                            // 涨 = 可选的房源更多，用能效最高档那个深绿；跌用次要色，
                            // **不用红**——房源少不是错误，红色会读成告警。
                            // 和统计带 (`StatsStrip.anchor`) 是同一条规则。
                            .foregroundStyle(pct >= 0 ? Color.energyTop : Color.secondary)
                    }
                }
            }
            // 和 Alerts 那张 24 小时图是同一个组件、同一个色 token。第三张迷你图
            // 再自己写一份的话，改配色就要改三处（见 ``Theme/chart`` 的注释）。
            // 没有序列就**整块不摆**，而不是摆一个空的 32pt 高的框。
            // `BucketChart` 自己带 `maxWidth: .infinity`，空数组时它照样把右半边
            // 占满——空状态那张图上是一个大写的 `NEW TODAY`、一个破折号，
            // 和右边一大片什么都没有的留白，读起来像画到一半崩了。
            if !panel.series.isEmpty {
                // 1.5 是稿子给的。这里**必须**给，默认那个胶囊在 6pt 宽的柱子上
                // 会画成一排药丸（见 ``BucketChart/cornerRadius``）。
                BucketChart(values: panel.series, height: 32, cornerRadius: 1.5)
                    .frame(height: 32, alignment: .bottom)
            }
        }
        .padding(.horizontal, Self.textInset)
        .padding(.top, 11)
    }

    // MARK: - 筛选

    /// 当前那份 `listing_filter` 的人话版本。
    ///
    /// 数据是**白拿的**：``UserInfo/listingFilter`` 随登录一起回来，设置页改完
    /// 也会就地替换（`FilterSettings.apply`）。这里不发任何请求，也因此不会和
    /// 设置页显示成两个不同的筛选。
    ///
    /// 为什么没筛也要占一行
    /// ------------------
    /// 因为上面那个数字的口径取决于它。`No filters` 是在说「这 31 条是全库的」，
    /// 不是一句废话——用户看到一个意外的数字时，第一个要排除的就是"是不是我筛错了"。
    @ViewBuilder
    private var filterBand: some View {
        // 访客整行收起而不是显示 `No filters`：后者会被读成「你可以去设一个」，
        // 而访客设不了（那份 filter 属于账号）。
        if let summary = panel.filterSummary {
            SettingsLink {
                HStack(spacing: 7) {
                    Text("Filter")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
                .background(Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Self.bandInset)
            .padding(.top, 11)
        }
    }

    // MARK: - 最新

    @ViewBuilder
    private var newest: some View {
        // 空的时候连标题一起收走。只剩一个 `NEWEST` 悬在那儿，读起来是"加载失败"
        // 而不是"暂时没有"——小组件那一轮已经栽过一次。
        if !panel.rows.isEmpty {
            HStack(spacing: 8) {
                SectionHeading(StatusWording.newest)
                Spacer(minLength: 0)
                unreadPill
            }
            .padding(.horizontal, Self.textInset)
            .padding(.top, 14)
            .padding(.bottom, 6)

            VStack(spacing: 2) {
                ForEach(panel.rows) { row in
                    listingRow(row)
                }
            }
            .padding(.horizontal, Self.bandInset)
        }
    }

    @ViewBuilder
    private var unreadPill: some View {
        // 0 的时候不画。一枚红胶囊写着 0 只会让人以为坏了；访客那边由
        // ``MenuBarPanel`` 直接把 unread 置 0（个人通知流对访客是关的，风险 6）。
        if panel.unread > 0 {
            Text("\(panel.unread)")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 17, minHeight: 17)
                .background(Theme.unread, in: Capsule())
                .accessibilityLabel(StatusWording.unread)
        }
    }

    private func listingRow(_ row: MenuBarPanel.Row) -> some View {
        Button {
            onOpenRow(row)
        } label: {
            HStack(spacing: 9) {
                // 状态色走和状态胶囊同一条路（``Theme/statusColor(_:)``），
                // 不自己判一遍 status 串——那个归一化要认六七种写法。
                Diamond()
                    .fill(Theme.statusColor(row.status))
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(row.price)
                        .font(.system(.callout, design: .monospaced))
                        .monospacedDigit()
                    Text(row.age)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // 右边这一列不许被压缩：价格和时间都是短串，被挤成省略号
                // 就完全失去意义，该让步的是左边那个可以截断的标题。
                .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 「行悬停沿用表格的浮起投影」——稿子的原话。这里不自己写一遍配方，
        // 用全 App 那一份 ``RowSurface``。
        .modifier(RowSurface(isSelected: false, isHovered: hoveredRow == row.id))
        .onHover { hoveredRow = $0 ? row.id : nil }
    }

    // MARK: - 下一个能抢的日子

    /// 稿子那条琥珀横幅，内容换成了真有的那个日期（见类型注释）。
    ///
    /// 颜色用 ``Color/statusLottery``：抽签那个橙。虽然内容不再是抽签，但它在
    /// 这一屏里的角色没变——**唯一一条带时限的信息**，而那个橙在全 App 就是
    /// "这件事有窗口期"的意思。
    @ViewBuilder
    private var moveInBand: some View {
        if let next = panel.nextMoveIn {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.statusLottery)
                    .frame(width: 7, height: 7)
                Text(StatusWording.nextMoveInOn(ServerTime.shortDate(next.date)))
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(StatusWording.inDays(next.days))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Color.statusLottery.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, Self.bandInset)
            .padding(.top, 12)
        }
    }

    // MARK: - 底部三项

    /// 稿子底下那三行：`Open FlatRadar ⌘O` / `Settings… ⌘,` / `Quit ⌘Q`。
    ///
    /// 上一版是两个药丸按钮（Open 一个、Refresh + Quit 一排）。改成菜单项样式
    /// 是因为**这确实是一个菜单栏面板**：系统里每一个菜单栏 app 的底部都长这样，
    /// 右边那列快捷键是它的一部分。Refresh 挪到了页眉右上角那个圆圈——它是"再拿
    /// 一次数据"，和这三个"去别处"不是一类动作。
    private var actions: some View {
        VStack(spacing: 1) {
            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 9)

            MenuRow(title: "Open FlatRadar", shortcut: "⌘O", action: onOpenApp)

            SettingsLink {
                MenuRowLabel(title: "Settings…", shortcut: "⌘,")
            }
            .buttonStyle(.plain)

            MenuRow(title: "Quit", shortcut: "⌘Q", dimmed: true, action: onQuit)
        }
        .padding(.horizontal, Self.bandInset)
    }
}

// MARK: - 接线

/// 把 ``AppFeed`` / ``AuthStore`` 上那些活的东西，折成 ``MenuBarPanel`` 交给上面那个视图。
///
/// 这一层只做两件事：算那份值，和执行动作。没有任何摆放。
struct MenuBarStatusView: View {

    let feed: AppFeed
    let auth: AuthStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var refreshing = false

    var body: some View {
        MenuBarPanelView(
            panel: MenuBarPanel(feed: feed, auth: auth),
            refreshing: refreshing,
            onRefresh: { Task { await refresh() } },
            onOpenRow: open(_:),
            onOpenApp: openApp,
            onQuit: { NSApp.terminate(nil) })
            // 打开面板就刷一次：菜单栏的数字过时了比没有更糟——它会被当成"刚扫完"。
            .task { await refresh() }
    }

    private func openApp() {
        // 判据：「关闭所有窗口后菜单栏仍可查看状态并**重开窗口**」。
        //
        // `openWindow(id:)` 打开的是主 `WindowGroup`。如果已经有一个主窗口开着，
        // 这里走的是"把它激活"，不会再堆一个——`WindowGroup` 对无参场景的语义
        // 就是这样。
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: FlatRadarMacApp.mainWindowID)
        dismiss()
    }

    private func open(_ row: MenuBarPanel.Row) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: FlatRadarMacApp.listingWindowID, value: row.id)
        dismiss()
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await feed.refreshShared(auth: auth, forPanel: true)
        refreshing = false
    }
}

extension MenuBarPanel {

    /// 从活数据折一份出来。
    ///
    /// 访客那两条规则在这里**一次性**处理掉（未读置 0、筛选置 nil），而不是在
    /// 视图里到处 `if auth.isGuest`：那样每加一块就要记得再判一次，而漏判的表现
    /// 是给访客显示一个永远是 0 的数，不会有任何东西报错。
    init(feed: AppFeed, auth: AuthStore) {
        let guest = auth.isGuest
        self.init(
            newToday: feed.summary.newToday,
            changeVsBaseline: feed.summary.changeVsBaseline,
            series: feed.summary.series,
            scannedAgo: feed.summary.scannedAgoText,
            offline: feed.summary.failed,
            filterSummary: guest ? nil : (auth.userInfo?.listingFilter ?? .empty).summary,
            unread: guest ? 0 : feed.alerts.unreadCount,
            rows: feed.recentListings.map(Row.init(listing:)),
            nextMoveIn: Self.nextMoveIn(in: feed, now: Date()))
    }

    /// 下一个有货可抢的日子，和它离今天几天。
    ///
    /// `nextBookable` 找的是 `bookable > 0` 而不是 `total > 0`——后者的第一个命中
    /// 多半是一堆 Occupied 的退租日，点进去什么也做不了。理由和算法都在
    /// ``MoveInDay/nextBookable(in:)``，这里不重算。
    ///
    /// 天数用 ``ServerTime/calendar``，不是 `Calendar.current`：跨月时两者会差
    /// 一个月，而且只在 UTC 的机器上复现。
    private static func nextMoveIn(in feed: AppFeed, now: Date) -> (date: Date, days: Int)? {
        let series = MoveInDay.series(listingsByDay: feed.calendar.listingsByDay,
                                      from: now, days: AppFeed.moveInDays)
        guard let next = MoveInDay.nextBookable(in: series), let date = next.date else { return nil }
        let cal = ServerTime.calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now),
                                      to: cal.startOfDay(for: date)).day ?? 0
        return (date, max(days, 0))
    }
}

extension MenuBarPanel.Row {

    init(listing: Listing) {
        self.init(
            id: listing.id,
            title: listing.name,
            subtitle: [listing.city, Platform.displayName(listing.source)]
                .filter { !$0.isEmpty }
                .joined(separator: " · "),
            price: listing.priceRaw ?? "—",
            age: listing.firstSeen.map { ServerTime.compactAge($0, now: Date()) } ?? "",
            status: ListingStatus.from(listing.status))
    }
}

// MARK: - 零件

/// 分区小标题：`NEW TODAY` / `NEWEST`。
///
/// 稿子给的是 9.5px 加 1.2 的字距。9.5 落在 HIG 的 10pt 下限以下（``Theme``
/// 顶部那条「文字不写 10pt 以下」），所以取 `.caption` 的 10pt，字距照抄——
/// 全大写短标签的字距是它读得出来的关键，那个不是字号的事。
private struct SectionHeading: View {

    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }
}

/// 底部那三行的外观。抽出来是因为 `Settings…` 那行必须包在 `SettingsLink`
/// 里（见 ``SidebarView`` 的注释：它由 SwiftUI 直接连到 Settings 场景，设置窗口
/// 已经开着时会把它拿到前面），而另外两行是普通 Button——外观得是同一份，
/// 否则三行里有一行的字重或间距会差一点。
private struct MenuRowLabel: View {

    let title: LocalizedStringKey
    let shortcut: String
    var dimmed = false

    var body: some View {
        HStack(spacing: 9) {
            Text(title)
                // 控件里的文字走 `.body`，不跟数据那四档走（``Theme`` 顶部）。
                .font(.body)
                .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            Spacer(minLength: 0)
            Text(shortcut)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
    }
}

private struct MenuRow: View {

    let title: LocalizedStringKey
    let shortcut: String
    var dimmed = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title: title, shortcut: shortcut, dimmed: dimmed)
        }
        .buttonStyle(.plain)
        .background(hovered ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovered = $0 }
    }
}

// MARK: - 菜单栏上那个图标

/// 数字换成了**今日新增**。
///
/// 上一版显示的是匹配数。稿子 t5 的第一句话就是「菜单栏图标本身显示今日新增数
/// （红点＝有未读）」，而理由和面板锚点那条是同一个：匹配数是个几百的存量，
/// 挂在菜单栏上一整天都不动一下，占着那块地方却不构成任何"该看一眼了"的信号。
///
/// 未读标记只在**有未读**时出现，和面板里那枚胶囊是同一个数、同一条访客规则。
struct MenuBarStatusLabel: View {

    let feed: AppFeed
    let auth: AuthStore

    private var unread: Int {
        auth.isGuest ? 0 : feed.alerts.unreadCount
    }

    @Environment(\.openWindow) private var openWindow
    @Environment(RouteInbox.self) private var routes

    var body: some View {
        Image(nsImage: MenuBarGlyph.image(newToday: feed.summary.newToday,
                                          hasUnread: unread > 0))
            .accessibilityLabel(accessibilityText)
            // 一个窗口都没开过、只有菜单栏这一格的启动形态下（系统按"零窗口"恢复），
            // 这是进程里唯一挂着的视图。在这儿也登记一份开窗动作，点通知才开得出窗口。
            .onAppear {
                routes.registerWindowOpener { [openWindow] in
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: FlatRadarMacApp.mainWindowID)
                }
            }
    }

    private var accessibilityText: String {
        var parts = ["FlatRadar"]
        if let n = feed.summary.newToday { parts.append(String(localized: "\(n) new")) }
        if unread > 0 { parts.append(String(localized: "\(unread) unread")) }
        return parts.joined(separator: ", ")
    }
}

/// 菜单栏那一格的字形——**整个画成一张 template 图**交给系统。
///
/// 为什么不直接写 `HStack { Image; Text }`
/// ------------------------------------
/// 上一版就是那么写的，房子比数字低了一截。量出来（2x 像素，菜单栏 48px 高）：
///
/// | | 上沿 | 下沿 | 高 |
/// |---|---|---|---|
/// | 🏠 | 17 | **43** | 27 |
/// | `36` | 19 | **37** | 19 |
///
/// 房子底边比数字基线低 3pt。原因不在这边的代码：`MenuBarExtra` 会把 label
/// 拆开交给 `NSStatusBarButton`——`Image` 进 `image`、`Text` 进 `title`，
/// AppKit 各排各的，图按按钮高度居中、字按自己的基线放，**两者之间没有任何
/// 对齐关系**。在 SwiftUI 这边写什么 `alignment` / `baselineOffset` 都会在这次
/// 转换里丢掉。同一次转换还会丢掉一切不是 `Image` / `Text` 的东西——上一版那颗
/// 未读菱形是个自定义 `Shape`，**从来没被画出来过**。
///
/// 画成一张图之后排版就全在我们手里了。房子用 SF Symbol **插进 `Text`**：
/// 那样它按字体度量坐在基线上、高度跟着字号走——SF Symbols 设计时就是这么和
/// 文字对齐的，不用自己算偏移。
///
/// 为什么是 template
/// ----------------
/// 菜单栏的深浅跟**壁纸**走，不跟 app 的外观走；点开时那一格还会反色高亮。
/// template 图只留 alpha，由系统上色，这几种情况全对。代价是**不能有颜色**：
/// 稿子里那颗红菱形在这里是和数字同色的实心菱形——靠"有没有"区分未读，
/// 不靠红。要红就得出一张非 template 图，并且自己判断菜单栏此刻是深是浅，
/// 那一步判断错了整格就会在某些壁纸上消失。
struct MenuBarGlyph: View {

    let newToday: Int?
    let hasUnread: Bool

    /// 和系统给状态栏标题用的是同一个字体，数字的样子和上一版完全一样——
    /// 这次要动的只是房子，不是字。
    static var font: Font { Font(NSFont.menuBarFont(ofSize: 0)) }

    var body: some View {
        Text("\(Image(systemName: "house"))\(number)\(unreadMark)")
            .font(Self.font)
            .monospacedDigit()
            .foregroundStyle(.black)
            .fixedSize()
    }

    /// 前面带一个空格，和房子隔开。没拿到数时整段省略，只剩房子。
    private var number: String {
        newToday.map { " \($0)" } ?? ""
    }

    /// 小一号的实心菱形，抬到数字的**视觉中线**上。
    ///
    /// 小字号的符号默认坐在基线上，比数字的中线低；`baselineOffset` 把它抬上去。
    /// 抬多少是渲染出来量的（`MenuBarPanelRenderTests` 那条对齐测试钉着）。
    private var unreadMark: Text {
        guard hasUnread else { return Text(verbatim: "") }
        let diamond = Text(Image(systemName: "diamond.fill"))
            .font(.system(size: 7, weight: .bold))
            .baselineOffset(Self.markLift)
        // 插值而不是 `Text + Text`：后者在这一代 SDK 上已经标了弃用。
        return Text(" \(diamond)")
    }

    static let markLift: CGFloat = 2

    /// 画成图。菜单栏那一格每次数变了就重画一次——一行字，代价可以忽略。
    ///
    /// ⚠️ 画完要**上下裁到墨迹为止**
    /// ------------------------------
    /// `Text` 的包围盒是整个行框：上面留着上伸部的空间、下面留着下伸部的空间，
    /// 两边不一样多。实测这张图 35px 高，墨迹上面空 4px、下面空 2px——墨迹中心比
    /// 图中心低 1px。`NSStatusBarButton` 按**图**的中心放，于是整格在菜单栏里比
    /// 旁边的系统图标低了一截（量的：旁边图标中心 29.5，这一格 31）。
    ///
    /// 裁到墨迹之后图中心就是字形的视觉中心，和系统图标一样居中。顺带一个好处：
    /// 房子永远是最高的那个字形，裁出来的高度就是房子的高度，数字从 `7` 变成 `36`
    /// 这一格不会上下跳。
    @MainActor
    static func image(newToday: Int?, hasUnread: Bool) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let renderer = ImageRenderer(content: MenuBarGlyph(newToday: newToday,
                                                           hasUnread: hasUnread))
        renderer.scale = scale
        guard let drawn = renderer.cgImage else { return NSImage() }
        let trimmed = trimmedToInk(drawn) ?? drawn
        let image = NSImage(cgImage: trimmed,
                            size: NSSize(width: CGFloat(trimmed.width) / scale,
                                         height: CGFloat(trimmed.height) / scale))
        image.isTemplate = true
        return image
    }

    /// 上下裁掉没有墨迹的行，左右不动（左右的空白是字距，裁了会贴边）。
    nonisolated static func trimmedToInk(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let _ = Optional(ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))),
              let data = ctx.data
        else { return nil }
        // 位图上下文的内存按行从**上**往下排，和 `cropping(to:)` 的坐标系一致。
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        func hasInk(_ row: Int) -> Bool { (0..<w).contains { px[(row * w + $0) * 4 + 3] > 0 } }
        guard let top = (0..<h).first(where: hasInk),
              let bottom = (0..<h).last(where: hasInk) else { return nil }
        return image.cropping(to: CGRect(x: 0, y: top, width: w, height: bottom - top + 1))
    }
}
