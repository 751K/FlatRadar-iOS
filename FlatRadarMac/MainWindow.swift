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

    /// 跨窗口共享的那一层：通知数据 + SSE、统计、匹配数。见 ``AppFeed``。
    @Environment(AppFeed.self) private var feed

    @State private var model = BrowseModel()
    /// 地图的数据层。**窗口级**，和 `BrowseModel.listings` 同理——
    /// 两个窗口各筛各的，共享一个实例会互相覆盖。
    @State private var mapStore = MapStore()
    /// 统计屏的数据层。**窗口级**：天数是每个窗口自己选的，
    /// 一个窗口看 7 天、另一个看 90 天是合理的用法。
    @State private var statsStore = StatsModel()
    @State private var showInspector = true

    /// 窗口内容区的宽度。地图那两块浮层要靠它判断自己有没有顶到窗口右边缘
    /// （见 `MapPane` 里 `atWindowTrailingEdge` 的注释）。
    ///
    /// 用 `.background` 里的空视图量，不影响布局；而且它只在**真的改窗口大小**时
    /// 才变——开合侧栏 / inspector 不会动它，所以不会把这个窗口的 body 卷进那两条
    /// 动画里（那正是上一次让右栏数字乱动的原因）。
    @State private var windowWidth: CGFloat = 0

    var body: some View {
        // **不要**给它加 `columnVisibility:` 绑定。
        //
        // 试过：为了让地图知道侧栏收没收，这里绑过一个 `@State`。后果是每次开合侧栏
        // 都会重算整个 `MainWindow.body`，而这次重算发生在侧栏那条动画的 transaction
        // 里——于是右栏那些**右对齐**的数值（Price / Area / Floor…）跟着做了一段
        // 位移动画。录屏逐帧量过：`€1766` 在收起瞬间左跳 30pt，再花半秒缓回原位。
        //
        // 地图要的那个信息改由 `MapPane` 自己从几何量出来（它本来就在测自己的
        // frame 做相机补偿），不用把窗口级状态搅进来。
        NavigationSplitView {
            SidebarView(model: model, summary: feed.summary)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        } detail: {
            content
                .inspector(isPresented: $showInspector) {
                    InspectorPane(model: model)
                        .inspectorColumnWidth(min: 270, ideal: 300, max: 420)
                }
                .toolbar { toolbar }
                // 右栏开关的菜单入口要能改它，所以把 binding 本身送上去。
                // 工具栏那个按钮原先是**唯一**的入口（连快捷键都没有），
                // 而工具栏是可以被藏起来的——藏了就再也打不开右栏。
                .focusedSceneValue(\.inspectorVisible, $showInspector)
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
        .background {
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                windowWidth = $0
            }
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
            // 截图模式落位。放在这里而不是 `RootView`：`MainWindow` 是认证之后
            // 才挂载的，跑到这一行时身份已经落地，不存在 iOS 那边「登录是异步的、
            // tab 是同步设的，设完又被重置回默认值」那种竞态。
            if let section = ScreenshotMode.section() { model.section = section }
            // 两个请求互不依赖，并发发出去。统计带慢一点不该挡住表格。
            //
            // 房源是**这个窗口的**（各排各的序、各筛各的），共享那一份是应用级的
            // （统计、通知、匹配数）。`loadOnce()` 幂等，第二个窗口出现时不会
            // 重复发请求。
            async let listings: Void = model.load()
            async let shared: Void = feed.loadOnce(auth: auth)
            _ = await (listings, shared)
        }
        // 内容窗口的开合要报给 ``AppFeed``：它据此决定 SSE 该不该活着。
        //
        // 风险 6 的原文是「已登录且**至少有一个内容窗口打开**时维持 SSE……
        // 最后一个窗口关闭且尚未启用菜单栏常驻时断流」。所以这是计数不是布尔——
        // 两个窗口关掉一个，流不能断。
        //
        // 挂在 `MainWindow` 上而不是 `RootView` 上：登录屏不算内容窗口。
        .onAppear { feed.windowAppeared(auth: auth) }
        .onDisappear { feed.windowDisappeared(auth: auth) }
        // 未读数会**自己**变：SSE 推一条新提醒过来，没有任何刷新调用发生。
        // 桌面上那一格显示着这个数，所以在这里补一次写。
        //
        // 只有开着窗口时才有这条路。菜单栏常驻、一个窗口都没有的形态下，
        // 那一格要等下一次刷新（打开菜单栏面板，或 ⌘R）——这是有意的：
        // 为了一个次要的数字去装一条常驻的写路径，不值得。它也不会因此说谎，
        // 快照旧了那行小字自己会改口，见 `WidgetSnapshot.footnote(at:)`。
        .onChange(of: feed.alerts.unreadCount) { feed.publishWidgetSnapshot(auth: auth) }
        .focusedSceneValue(\.browseModel, model)
        // 点了推送通知 → 切到 Alerts 屏，新来的那条就在最上面。
        //
        // 只切屏、不定位到具体哪一条：payload 里给的是 `listing_id` 不是通知 id，
        // 同一套房可能有好几条通知。App 没在运行时点通知，系统会先把它拉起来，
        // 这时窗口还没出现、这里还没订阅，那一次点击就只是打开 App。
        .onReceive(NotificationCenter.default.publisher(for: .flatRadarOpenAlerts)) { _ in
            model.section = .alerts
        }
        // `h2smonitor://map/<id>` —— 切到地图屏并定位过去，和右键菜单的
        // 「Show on Map」走同一条路。
        .onReceive(NotificationCenter.default.publisher(for: .flatRadarLocateOnMap)) { note in
            guard let id = note.userInfo?["listing_id"] as? String else { return }
            model.locateOnMap(id: id)
        }
        // 日历数据**按需**拉，不跟着启动一起发。
        //
        // 它是四屏里最少打开的一屏，而 `/calendar` 实测回 691 条、211 KB——
        // 让它和 listings、stats 抢启动那一下的带宽不划算。`fetch()` 自己有
        // `guard !isLoading` 去重，来回切屏不会重复发。
        .onChange(of: model.section) { _, section in
            guard section == .calendar, feed.calendar.listings.isEmpty else { return }
            Task { await feed.calendar.fetch() }
        }
        // 通知的取数和 SSE 都移到了 ``AppFeed``（上面那个 `loadOnce()`）。
        //
        // 原先这里是一个 `.task { await alerts.fetch(); alerts.connectStream() }`。
        // 只有一个窗口时没问题，⌘N 之后就是**两条 SSE**：`connectStream()` 里那个
        // `guard streamTask == nil` 只拦得住同一个 store 连两次，而那时每个窗口
        // 各有一个 `NotificationsStore`。风险 6 写的是「每个会话最多一条通知流」。
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        paneBody
            // 截图自动化靠它确认「现在显示的是哪一屏」。
            //
            // 不验侧栏那一行的选中态：macOS 上那些行的 AX label 是**空的**
            // （build 359 实测，六行全是 ""），按文案根本找不到；而且就算找到了，
            // 「哪一行高亮」也只是间接证据。这里直接给内容区打标，验的就是判据
            // 本身——拍下来的这一屏到底是不是它该是的那一屏。
            .accessibilityIdentifier("pane-\(model.section.rawValue)")
    }

    @ViewBuilder
    private var paneBody: some View {
        switch model.section {
        case .listings:
            ListingsPane(model: model, summary: feed.summary)
        case .map:
            MapPane(model: model, store: mapStore, windowWidth: windowWidth)
        case .calendar:
            CalendarPane(model: model, store: feed.calendar)
        case .alerts:
            AlertsPane(model: model, store: feed.alerts)
        case .stats:
            StatsPane(model: model, stats: statsStore)
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
                    async let b: Void = feed.refreshShared(auth: auth)
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
