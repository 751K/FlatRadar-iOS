import SwiftUI

/// 给 NotificationsView 的 tab item 单独挂红点，**故意**抽成 ViewModifier：
/// 让对 `NotificationsStore.unreadCount` 的观察只发生在这个小 modifier 的 body 里。
///
/// 之前 MainTabView 自己 `@Environment(NotificationsStore.self)` + 在 body 里读
/// `notifStore.unreadCount`，每次 SSE 推一批通知导致 unreadCount 跳，整个 MainTabView.body
/// 就会重跑——TabView 也跟着重跑——DashboardView 内的 `.refreshable` / `.task` 就被
/// SwiftUI cancel，正在飞的 URLSession 请求统统抛 `NSURLErrorCancelled (-999)`，UI
/// 看到的就是"连接失败"。
///
/// 抽到这里后，badge 变化只让这个 modifier 的 wrapper view 重跑，MainTabView 不受影响。
private struct AlertsTabBadge: ViewModifier {
    @Environment(NotificationsStore.self) private var notifStore
    func body(content: Content) -> some View {
        content.badge(notifStore.unreadCount)
    }
}

struct MainTabView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(NavigationCoordinator.self) private var coord

    /// TabView 的 selection。
    ///
    /// **getter 必须保证返回的 tab 在当前形态下是可见的。** 这不是洁癖，是崩溃修复：
    ///
    /// iPad Pro 11 寸竖屏 834pt、横屏 1194pt，转屏正好跨过 `shouldUseCompactTabs`
    /// 的 920。翻转的瞬间 `.browse` 从可见变隐藏，而 `coord.selectedTab` 要等
    /// `.onChange(of: useCompactTabs)` 里的 `normalizeSelection` 才会被改写——那
    /// 发生在视图更新之后。中间那一帧 TabView 的 selection 指着一个
    /// `.hidden(true)` 的 tab，iOS 18 的 TabView 在这里直接 abort。
    ///
    /// 迁移之前不存在这个窗口：compact / wide 是两个各自完整的 TabView，
    /// `if useCompactTabs` 切换时整个 TabView 被换掉，新 selection 落在一个全新的
    /// TabView 上。合并成一个 TabView 之后，"tab 集合变化"和"selection 变化"成了
    /// 两个独立的时刻，中间就有了缝。
    ///
    /// 所以不靠 onChange 去追平，而是让 getter 现算：selection 是**派生值**，
    /// 缝就不存在了。`normalizeSelection` 仍然保留，它负责把规范化后的值写回
    /// coordinator（deep link、键盘快捷键、下次启动都读那个值）。
    private func tabSelection(compact: Bool) -> Binding<AppTab> {
        Binding(
            get: { Self.visibleTab(coord.selectedTab,
                                   compact: compact,
                                   browseMode: coord.selectedBrowseMode) },
            set: { newValue in
                coord.selectedTab = newValue
                // 宽窗口下点 Listings / Map / Calendar 时同步 browseMode，
                // 这样转回竖屏时 Browse 里落在同一个模式上，不用等 onChange。
                switch newValue {
                case .listings: coord.selectedBrowseMode = .list
                case .map:      coord.selectedBrowseMode = .map
                case .calendar: coord.selectedBrowseMode = .calendar
                default:        break
                }
            }
        )
    }

    /// 把任意 tab 映射成当前形态下**可见**的那一个。纯函数，没有副作用。
    /// `nonisolated` + 非 private：它是纯函数，而且是 TabSelectionTests 守的东西。
    nonisolated static func visibleTab(_ tab: AppTab,
                                       compact: Bool,
                                       browseMode: BrowseMode) -> AppTab {
        if compact {
            switch tab {
            case .listings, .map, .calendar: return .browse
            default:                         return tab
            }
        }
        guard tab == .browse else { return tab }
        switch browseMode {
        case .list:     return .listings
        case .map:      return .map
        case .calendar: return .calendar
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let useCompactTabs = shouldUseCompactTabs(width: proxy.size.width)

            ZStack {
                tabView(compact: useCompactTabs)
                keyboardShortcuts(compact: useCompactTabs)
            }
            .toolbarBackground(.ultraThinMaterial, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .onChange(of: coord.selectedTab) { _, new in
                normalizeSelection(new, compact: useCompactTabs)
            }
            .onChange(of: useCompactTabs) { _, new in
                normalizeSelection(coord.selectedTab, compact: new)
            }
            .onAppear {
                normalizeSelection(coord.selectedTab, compact: useCompactTabs)
            }
        }
    }

    // MARK: - Tabs

    /// 一份 tab 定义，两套形态。
    ///
    /// 以前是 `compactTabView` / `wideTabView` 两个各自完整的 TabView，靠
    /// `if useCompactTabs` 二选一。iOS 18 的 `TabContent.hidden(_:)` 让同一个
    /// TabView 能同时装下两套 tab 集合，按需隐藏其中几个——Dashboard / Alerts /
    /// Settings 这三个原本要写两遍的，现在只写一遍。
    ///
    /// 判据仍然是**宽度**而不是 horizontal size class。Apple 文档里的等价例子用的
    /// 是 size class，但那对这个 App 是错的：iPad 的 Stage Manager / Split View
    /// 会在窗口已经窄到放不下六个 tab 时仍然报 regular。见 `shouldUseCompactTabs`。
    ///
    /// `accessibilityIdentifier` 现在挂在 **tab 自己**身上（`TabContent` 的修饰符），
    /// 不再是 `.tabItem { Label(…).accessibilityIdentifier(…) }`。旧写法在 iPhone 上
    /// 会被 UITabBar 吞掉——build 265 实测 `id=""`，而 iPad 那边是好的，
    /// ScreenshotTests 至今为此分设备写两条查询路径。新 API 把 identifier 提到了
    /// tab 层级，**有可能**把这个差异抹平；能不能真抹平要跑一次截图套件才知道。
    @TabContentBuilder<AppTab>
    private func tabs(compact: Bool) -> some TabContent<AppTab> {
        Tab(value: AppTab.dashboard) {
            DashboardView()
        } label: {
            Label("Dashboard", systemImage: "chart.bar.fill")
        }
        .accessibilityIdentifier("tab-dashboard")

        // 窄：List / Map / Calendar 收进 Browse 里的 segmented picker
        Tab(value: AppTab.browse) {
            BrowseView()
        } label: {
            Label("Browse", systemImage: "square.grid.2x2.fill")
        }
        .accessibilityIdentifier("tab-browse")
        .hidden(!compact)

        // 宽：三个平铺成独立 tab。
        //
        // 曾经把它们包进 `TabSection("Browse")`，想让侧边栏里多一层分组标题。
        // 那是错的：sidebarAdaptable 的**顶部 tab bar** 会把整个 section 折叠成
        // 一个叫 "Browse" 的条目，三个子 tab 只有展开侧边栏才够得着——横屏 iPad
        // 上等于把 Listings / Map / Calendar 藏了起来。
        //
        // TabSection 是给「次级、可折叠、数量会变」的那类分组用的（Apple 的例子
        // 是播放列表）。这三个是并列的主视图，平铺才对。
        Tab(value: AppTab.listings) {
            listingsTab
        } label: {
            Label("Listings", systemImage: "list.bullet")
        }
        .accessibilityIdentifier("tab-listings")
        .hidden(compact)

        Tab(value: AppTab.map) {
            mapTab
        } label: {
            Label("Map", systemImage: "map.fill")
        }
        .accessibilityIdentifier("tab-map")
        .hidden(compact)

        Tab(value: AppTab.calendar) {
            calendarTab
        } label: {
            Label("Calendar", systemImage: "calendar")
        }
        .accessibilityIdentifier("tab-calendar")
        .hidden(compact)

        if auth.role == .user || auth.role == .admin {
            Tab(value: AppTab.notifications) {
                // badge 仍然挂在**内容视图**上，和迁移前一模一样。
                // 不写成 `.badge(notifStore.unreadCount)`：那要在这里读 store，
                // 而 AlertsTabBadge 存在的全部理由就是不让 unreadCount 的变化
                // 打到 MainTabView.body 上（见文件顶部注释）。TabContent 没有
                // 对应的 modifier 协议，所以保持原样是唯一不破坏隔离的写法。
                NotificationsView()
                    .modifier(AlertsTabBadge())
            } label: {
                Label("Alerts", systemImage: "bell.fill")
            }
            .accessibilityIdentifier("tab-alerts")
        }

        Tab(value: AppTab.settings) {
            SettingsView()
        } label: {
            Label("Settings", systemImage: "gear")
        }
        .accessibilityIdentifier("tab-settings")
    }

    private func tabView(compact: Bool) -> some View {
        TabView(selection: tabSelection(compact: compact)) {
            tabs(compact: compact)
        }
        // iPhone 底部 tab bar 不变；iPad 变成顶部 tab bar，可展开成侧边栏。
        .tabViewStyle(.sidebarAdaptable)
        // **默认落在顶部 tab bar，而不是侧边栏。**
        //
        // `.sidebarAdaptable` 在 iPad **横屏**下默认展开成侧边栏。那不是我们要的：
        // 侧边栏吃掉约 320pt，而这个 App 的横屏布局（Dashboard 左右分栏、日历
        // 左右分栏）正是靠那点宽度换来的——侧边栏一开，左栏就掉回窄形态。
        //
        // 这条是 build 295 逼出来的。那次把 iPad 截图改成横屏之后 35 张全挂，
        // 失败信息里的按钮清单说得很清楚：
        //
        //     tabBars=0
        //     id="ToggleSidebar" label="Ocultar barra lateral"   ← 「隐藏侧边栏」
        //
        // 也就是说界面确实起来了（清单里 Dashboard 的内容一应俱全），只是 tab
        // 变成了侧边栏里的行、不再是 `app.buttons` 里带 `tab-` identifier 的按钮，
        // 截图套件 60 秒等不到，七条 × 五语言全部超时。竖屏时默认是顶部 tab bar，
        // 所以 build 293 没暴露。
        //
        // `.automatic` 交给系统按朝向决定，`.tabBar` 是明确要求「一律用顶部」。
        .defaultAdaptableTabBarPlacement(.tabBar)
    }

    // MARK: - iPad tab content

    private var listingsTab: some View {
        NavigationStack(path: Binding(
            get: { coord.listingsPath },
            set: { coord.listingsPath = $0 }
        )) {
            ListingsView()
                .navigationDestination(for: ListingRoute.self) { route in
                    ListingDetailView(route: route)
                }
        }
    }

    private var mapTab: some View {
        NavigationStack {
            MapView()
        }
    }

    private var calendarTab: some View {
        NavigationStack {
            CalendarView()
        }
    }

    // MARK: - Keyboard shortcuts

    private func shouldUseCompactTabs(width: CGFloat) -> Bool {
        // iPad Stage Manager / Split View can keep a regular size class even
        // when the window is too narrow for six top tabs. Switch to Browse
        // once the actual content width gets tight.
        width < 920
    }

    private func keyboardShortcuts(compact: Bool) -> some View {
        HStack(spacing: 0) {
            shortcutButton("Switch to Dashboard", key: "1") { coord.selectedTab = .dashboard }
            if !compact {
                shortcutButton("Switch to Listings", key: "2") { coord.selectedTab = .listings }
                shortcutButton("Switch to Map", key: "3") { coord.selectedTab = .map }
                shortcutButton("Switch to Calendar", key: "4") { coord.selectedTab = .calendar }
                shortcutButton("Switch to Alerts", key: "5") { coord.selectedTab = .notifications }
                shortcutButton("Switch to Settings", key: "6") { coord.selectedTab = .settings }
            } else {
                shortcutButton("Switch to Browse", key: "2") { coord.selectedTab = .browse }
                shortcutButton("Switch to Alerts", key: "3") { coord.selectedTab = .notifications }
                shortcutButton("Switch to Settings", key: "4") { coord.selectedTab = .settings }
            }
        }
        .hidden()
        .frame(width: 0, height: 0)
        // .hidden() 已经把 HStack 视觉隐藏；同时对 VoiceOver 显式跳过，
        // 否则 VO 仍能聚焦到这些"空标签按钮"——既然有 accessibilityLabel
        // 防御性也好，再用 accessibilityHidden 把整组从 a11y 树移除最干净。
        // 这些 button 只是 keyboardShortcut 接收器，硬件键盘用户走快捷键，
        // VoiceOver 用户走真实的 tab bar，重复曝光反而干扰。
        .accessibilityHidden(true)
    }

    /// 把命令键 shortcut 包成有 accessibilityLabel 的按钮 —— 即便整体走
    /// accessibilityHidden 屏蔽，单元素仍带 label 是好习惯：
    /// 一是日后想曝光时只需删 .accessibilityHidden(true)；二是某些辅助工具
    /// （非 VoiceOver）会扫 label 内容。
    private func shortcutButton(
        _ label: String,
        key: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: .command)
            .accessibilityLabel(label)
    }

    private func normalizeSelection(_ tab: AppTab, compact: Bool) {
        if compact {
            switch tab {
            case .listings:
                coord.selectedTab = .browse
                coord.selectedBrowseMode = .list
            case .map:
                coord.selectedTab = .browse
                coord.selectedBrowseMode = .map
            case .calendar:
                coord.selectedTab = .browse
                coord.selectedBrowseMode = .calendar
            default:
                break
            }
        } else if tab == .browse {
            switch coord.selectedBrowseMode {
            case .list:
                coord.selectedTab = .listings
            case .map:
                coord.selectedTab = .map
            case .calendar:
                coord.selectedTab = .calendar
            }
        }
    }
}
