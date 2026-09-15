import SwiftUI
import FlatRadarCore

/// 主窗口：侧栏 + 内容 + inspector。
///
/// 这一层是**框架**，四屏的内容各自在自己的文件里。拆出来的直接理由：
/// 之前 `BrowseWindow` 自己攥着 `NavigationSplitView`，再加一屏地图的话，
/// 地图会长出第二个详情面板——而三屏共用一个 inspector 正是 Mac 版的主要收益。
///
/// 为什么右栏用 `.inspector` 而不是三栏 `NavigationSplitView`
/// -------------------------------------------------------
/// 两者都能画出三栏，但语义不同：`NavigationSplitView` 的第三栏是**导航目的地**
/// （选了左边，右边是"打开"的那个东西），而这里右栏是**当前选中项的检视器**，
/// 内容区自己才是目的地。`.inspector` 还白送了工具栏开关和记忆宽度。
struct MainWindow: View {

    @Environment(AuthStore.self) private var auth

    @State private var model = BrowseModel()
    @State private var summary = SummaryModel()
    /// 地图的数据层。**窗口级**，和 `BrowseModel.listings` 同理——
    /// 两个窗口各筛各的，共享一个实例会互相覆盖。
    @State private var mapStore = MapStore()
    /// 日历的数据层。**窗口级**，和 ``mapStore`` 同理。
    @State private var calendarStore = CalendarStore()
    /// 通知的数据层。**窗口级**，和另外两个同理。
    @State private var alerts = NotificationsStore()
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, summary: summary)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        } detail: {
            content
                .inspector(isPresented: $showInspector) {
                    InspectorPane(model: model)
                        .inspectorColumnWidth(min: 270, ideal: 300, max: 420)
                }
                .toolbar { toolbar }
                // 顶栏**不画自己那层材质**。
                //
                // 原先的样子：AppKit 默认会在整条 titlebar 上盖一层材质，而它盖在
                // 三种不同的底上——左边侧栏的玻璃、中间内容区的实色底、右边
                // inspector 的玻璃——合成出来是三个色调。于是那条横栏在
                // 「侧栏右边界」和「inspector 左边界」各断一次，断点正好是两个
                // 交叉点，看着像一条栏被切成了三截。
                //
                // 去掉这层之后，三栏各自的底从窗口顶一路贯通到底，横栏不再是一个
                // 独立的面，只剩浮在上面的控件——这也是 macOS 26 的做法。
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .navigationTitle("FlatRadar")
        // 标题**留给窗口、不画在界面上**。
        //
        // 上面那行 `toolbarBackgroundVisibility(.hidden)` 撤掉顶栏材质之后，内容
        // 就直接铺到窗口顶了——地图屏尤其明显，地图整块贯通到顶。这时候
        // 「FlatRadar」这几个字是**压在地图上**的：平移到水面或深色街区就读不清，
        // 而且和左上角的 `All filters` 上下挤成一摞。
        //
        // 去掉的只是**画出来**的那份。`navigationTitle` 仍然设着，窗口菜单、
        // Mission Control、⌘` 循环里名字都还在。当前在哪一屏由侧栏的选中态回答，
        // 顶上再写一遍应用名不增加任何信息。
        .toolbar(removing: .title)
        // 强调色 = ink，没有色相。
        //
        // 设计稿 t1 的原话：七个平台色 + 五个状态色已经把色相空间占满，任何有色相的
        // 强调色都会在同一行里撞上——系统蓝会同时撞 H2S 蓝和 Reserved 蓝。
        // ink 与 Occupied 灰的明度差足够大，读作**结构墨色**而非状态色。
        //
        // 这也是 docs/DESIGN.md §8 那个待定项的答案：不选色相，冲突就不存在。
        .tint(Theme.ink)
        .task {
            // 两个请求互不依赖，并发发出去。统计带慢一点不该挡住表格。
            async let listings: Void = model.load()
            async let stats: Void = summary.load()
            _ = await (listings, stats)
        }
        .focusedSceneValue(\.browseModel, model)
        // 点了推送通知 → 切到 Alerts 屏，新来的那条就在最上面。
        //
        // 只切屏、不定位到具体哪一条：payload 里给的是 `listing_id` 不是通知 id，
        // 同一套房可能有好几条通知。App 没在运行时点通知，系统会先把它拉起来，
        // 这时窗口还没出现、这里还没订阅，那一次点击就只是打开 App。
        .onReceive(NotificationCenter.default.publisher(for: .flatRadarOpenAlerts)) { _ in
            model.section = .alerts
        }
        // 日历数据**按需**拉，不跟着启动一起发。
        //
        // 它是四屏里最少打开的一屏，而 `/calendar` 实测回 691 条、211 KB——
        // 让它和 listings、stats 抢启动那一下的带宽不划算。`fetch()` 自己有
        // `guard !isLoading` 去重，来回切屏不会重复发。
        .onChange(of: model.section) { _, section in
            guard section == .calendar, calendarStore.listings.isEmpty else { return }
            Task { await calendarStore.fetch() }
        }
        // 通知**跟着启动就拉**，不像日历那样按需——侧栏的未读徽章要用它，
        // 而徽章在四屏里都看得见。SSE 也一起接上：这一屏的价值就在实时。
        .task {
            await alerts.fetch()
            alerts.connectStream()
        }
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .listings:
            ListingsPane(model: model, summary: summary)
        case .map:
            MapPane(model: model, store: mapStore)
        case .calendar:
            CalendarPane(model: model, store: calendarStore)
        case .alerts:
            AlertsPane(model: model, store: alerts)
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // 把后面三个按钮顶到右上角。
        //
        // 需要它是因为上面撤掉了画出来的标题：原先是**标题在占位**，自动布局把
        // 按钮挤到了右边；标题一没，三个按钮就滑到左边紧挨着侧栏开关，右上角空着。
        // 显式写出这个间隔，位置就不再依赖"标题恰好有多宽"这种隐性副作用。
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Button {
                Task {
                    async let a: Void = model.reload()
                    async let b: Void = summary.load()
                    _ = await (a, b)
                }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(model.listings.isLoading)
            .help("Reload listings (⌘R)")
        }
        ToolbarItem {
            Button {
                if let f = model.focused { model.togglePin(f) }
            } label: {
                Label("Pin for comparison", systemImage: "pin")
            }
            .disabled(model.focused == nil)
        }
        // `.inspector` **不会**自己在工具栏上放开关——它只管那一栏怎么显示。
        // 不补这个按钮的话，收起来之后没有任何入口再打开（没有默认快捷键）。
        // 实测：第一版工具栏只有 Hide Sidebar / Reload / Pin 三个。
        ToolbarItem {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(showInspector ? "Hide inspector" : "Show inspector")
        }
    }
}

/// 还没做的那几屏。
///
/// **明说它是占位，不假装有内容。** 侧栏留着 Map / Calendar / Alerts 三个条目是
/// 对的（它们是产品的一部分，见 docs/DESIGN.md §7.2），但点进来必须能看出
/// "这里还没做"，而不是一个空列表让人以为是没数据、或者加载失败。
private struct NotBuiltYet: View {

    let section: SidebarSection

    var body: some View {
        ContentUnavailableView {
            Label("\(section.label) — not built yet", systemImage: section.systemImage)
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detail: String {
        switch section {
        case .map:
            return ""
        case .calendar:
            return "日历排在 Phase 3，而且要全部自绘——iOS 用的 UICalendarView "
                 + "在 macOS 上不存在。形态本身也待定，见 docs/DESIGN.md §7.4。"
        case .alerts:
            return "通知排在 Phase 3。NotificationsStore 和 SSEClient 都在包里，"
                 + "缺的是界面和系统通知中心的对接。"
        case .listings:
            return ""
        }
    }
}
