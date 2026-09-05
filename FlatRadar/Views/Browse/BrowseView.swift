import SwiftUI
import UIKit

/// "Browse" tab — 把 Listings/Map/Calendar 三个"同一份数据的不同视图"合并到
/// 一个 tab，靠顶部 toolbar 的 segmented picker 切换模式。
///
/// 为什么合并
/// ----------
/// iPhone tab bar 最多显示 5 个 tab，多出来的自动塞 "More" 标签下折叠。我们
/// 之前 6 个 tab（含 Dashboard/Listings/Map/Calendar/Notifications/Settings）
/// → Notifications/Settings 中的一个被折叠，体验不好。
///
/// 这三个 view 本质都是浏览房源，合并后语义反而更干净，腾出 tab 给真正不同
/// 职责的 Notifications / Settings。
///
/// 设计
/// ----
/// - 单一 NavigationStack(path: $coord.listingsPath)，所有模式共享同一个导航栈
/// - `navigationDestination(for: ListingRoute.self)` 上提到这里，三个子视图
///   里直接 `NavigationLink(value: ListingRoute.xxx)` 即可 push 详情
/// - iPhone 上 segmented picker 放在 nav bar 左侧，避免不同子页 toolbar
///   组合后出现一页靠左、一页居中的跳动
/// - 每个子视图保留自己的 `.toolbar` 项（搜索框、刷新、Today 等），通过修饰
///   器累积合并到本视图的 NavigationStack
struct BrowseView: View {
    @Environment(NavigationCoordinator.self) private var coord
    @State private var hasMountedMap = false

    var body: some View {
        @Bindable var coord = coord

        NavigationStack(path: $coord.listingsPath) {
            content
            // 不显示 nav title：iPad inline picker / iPhone compactModeMenu
            // 都已标明当前模式，nav bar 里再写一遍 "Calendar" 冗余。
            // 但 nav bar 本身要保留布局高度——map 视图 ignoresSafeArea(.top)
            // 把地图穿到顶部，picker 靠 ZStack(.top) 落位；nav bar 高度塌掉
            // 会让 picker 直接顶到 status bar 下方。用 .toolbar(.visible,…)
            // 强制 nav bar 占位但内容空。
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            // 把 nav bar 背景锁到 systemGroupedBackground，避免 iPad portrait
            // 下系统默认 nav bar 透出白色 systemBackground 与下面灰底 insetGrouped
            // 列表分层。
            // 唯独 map 模式要例外——map 视图主动 ignoresSafeArea(.top) 让地图穿
            // 过顶部一直延伸到 status bar，picker 浮在地图上是设计本意。如果给
            // nav bar 加灰底，会切出一条灰带 + picker 突兀压在绿色地图上。
            .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(
                coord.selectedBrowseMode == .map ? .hidden : .visible,
                for: .navigationBar
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    compactModeMenu
                }
            }
            .navigationDestination(for: ListingRoute.self) { route in
                ListingDetailView(route: route)
            }
            .onAppear {
                if coord.selectedBrowseMode == .map {
                    hasMountedMap = true
                }
            }
            .onChange(of: coord.selectedBrowseMode) { _, mode in
                if mode == .map {
                    hasMountedMap = true
                }
            }
        }
    }

    /// List / Map / Calendar 三个模式共用一个 ZStack。
    ///
    /// 曾经分 iPad / iPhone 两套：iPad 走一个浮在地图上的 segmented picker，
    /// iPhone 走 nav bar 里的下拉菜单。改用 sidebarAdaptable 之后 iPad 的 tab bar
    /// 变成了顶部的浮动胶囊，那个 picker 就贴在它下面——两排选择器叠在一起，
    /// 第二排还在解释第一排里的一个条目，很难看。
    ///
    /// 而且那条分支本来就没有存在的理由了：Browse 这个 tab 只在窄窗口
    /// （`MainTabView` 里 `.hidden(!compact)`，宽度 < 920）才出现，宽屏 iPad 上
    /// List / Map / Calendar 是三个独立的顶层 tab，根本走不到这里。所以
    /// `usesInlineModePicker`（判据是 `idiom == .pad`）真正生效的场合只有
    /// "窄窗口的 iPad"——那正是该跟 iPhone 一致的场合。
    ///
    /// 两套合成一套，模式切换统一走 nav bar 里的 `compactModeMenu`。
    private var content: some View {
        // "按需创建，创建后保活"：Listing 首次打开不背着一个隐藏 MapKit 实例
        // 一起启动，切回 map 又不闪。List / Calendar 视图本身有不透明的
        // systemGroupedBackground，盖住下面的 map。
        ZStack {
            if shouldRenderMap {
                MapView()
                    .opacity(coord.selectedBrowseMode == .map ? 1 : 0)
                    .allowsHitTesting(coord.selectedBrowseMode == .map)
            }

            if coord.selectedBrowseMode != .map {
                nonMapContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground))
            }
        }
    }

    private var shouldRenderMap: Bool {
        hasMountedMap || coord.selectedBrowseMode == .map
    }

    /// 非 map 模式的内容 —— list 或 calendar。
    /// map 是外层 ZStack 永久保留的，这里不再渲染 MapView，
    /// 避免与外层的"持久 MapView"形成两个实例。
    @ViewBuilder
    private var nonMapContent: some View {
        switch coord.selectedBrowseMode {
        case .list:     ListingsView()
        case .calendar: CalendarView()
        case .map:      EmptyView()   // outer condition guarantees unreachable
        }
    }

    private var compactModeMenu: some View {
        @Bindable var coord = coord
        return Menu {
            Picker("Mode", selection: $coord.selectedBrowseMode) {
                ForEach(BrowseMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: coord.selectedBrowseMode.systemImage)
                    // 装饰性 icon：mode label 已经在右边了，重复朗读没意义
                    .accessibilityHidden(true)
                Text(coord.selectedBrowseMode.label)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    // chevron 只表示这是 menu，trait 已经传达"pop-up button"
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        // 整个 Menu 朗读："Mode, <current>, pop-up button"
        .accessibilityLabel("Browse mode")
        .accessibilityValue(coord.selectedBrowseMode.label)
    }
}
