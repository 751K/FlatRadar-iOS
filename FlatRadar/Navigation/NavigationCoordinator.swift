import Foundation
import SwiftUI
import FlatRadarCore

/// Tab 标识——MainTabView 用 ``selection`` 绑定。
///
/// iPhone compact: 4 tabs（Dashboard / Browse / Notifications / Settings），
/// Browse 内用 ``BrowseMode`` segmented picker 切换 List/Map/Calendar。
///
/// iPad regular: 6 tabs（Dashboard / Listings / Map / Calendar / Notifications / Settings），
/// 空间足够，不需要二级 picker。
enum AppTab: String, Hashable, Sendable {
    case dashboard
    case browse       // iPhone only
    case listings     // iPad only
    case map          // iPad only
    case calendar     // iPad only
    case notifications
    case settings
}

/// Browse tab 内的视图模式。
enum BrowseMode: String, Hashable, Sendable, CaseIterable, Identifiable {
    case list
    case map
    case calendar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list:     return String(localized: "List")
        case .map:      return String(localized: "Map")
        case .calendar: return String(localized: "Calendar")
        }
    }

    var systemImage: String {
        switch self {
        case .list:     return "list.bullet"
        case .map:      return "map.fill"
        case .calendar: return "calendar"
        }
    }
}

/// 程序内导航协调器。
///
/// 为什么需要
/// ----------
/// 1. **推送 deep link**：``PushDelegate`` 收到通知后只能 ``NotificationCenter.post``，
///    没法直接动 SwiftUI 视图。Coordinator 把 listing_id 接收下来，转成 tab
///    切换 + NavigationStack push。
/// 2. **URL Scheme**：``h2smonitor://listing/<id>`` 链接（邮件/iMessage 里点）
///    经 ``onOpenURL`` 也走同一个出口。
///
/// 用法
/// ----
/// - ``MainTabView`` ``$coordinator.selectedTab`` 绑定到 TabView selection
/// - ``ListingsView`` 用 ``$coordinator.listingsPath`` 作为 NavigationStack 的 path
/// - ``ListingsView.navigationDestination(for: ListingRoute.self)`` 负责实际绘制
///
/// 路由 enum (``ListingRoute``) 而不是直接塞 Listing：
/// push 通知只有 id，没有完整 Listing 对象；Detail 视图自己异步加载。
@MainActor
@Observable
final class NavigationCoordinator {
    var selectedTab: AppTab = NavigationCoordinator.initialTab
    var selectedBrowseMode: BrowseMode = .list

    /// 当前是不是「窄窗口」形态——List / Map / Calendar 三个视图挤在 Browse
    /// 这一个 tab 里，共用 ``listingsPath`` 那一个导航栈。
    ///
    /// 为什么要存一份
    /// -------------
    /// 判据是**内容宽度**（`MainTabView.shouldUseCompactTabs`，< 920），而那个
    /// 宽度只有 `MainTabView` 的 `GeometryReader` 量得到。别的视图要知道自己
    /// 身处哪种形态时，此前各自猜了一个——`UIDevice.current.userInterfaceIdiom
    /// == .pad`。那个判据在**窄窗口的 iPad** 上是错的，而 iPad 竖屏就是
    /// 834pt < 920，分屏和台前调度更窄，全都落在那一档。
    ///
    /// 写它的只有 `MainTabView` 一处（和 `normalizeSelection` 同步），读它的是
    /// 需要区分「我在 Browse 的栈里」还是「我是一个独立 tab」的那几个视图。
    ///
    /// 默认 `true`：iPhone 永远是这一档，而且猜窄的代价小——往 Browse 的栈里
    /// 推一层，最坏是多一次返回；猜宽则会把人从日历甩到列表去。
    var usesCompactTabs = true

    /// 启动时落在哪个 tab。只有 DEBUG 包认启动参数 `-initialTab <AppTab.rawValue>`，
    /// 给命令行验证用（`devicectl device process launch ... -initialTab calendar`），
    /// 真机上没法远程点 tab 栏。发布包一律 dashboard。
    private static var initialTab: AppTab {
        #if DEBUG
        if let tab = debugArgument("-initialTab").flatMap(AppTab.init(rawValue:)) {
            return tab
        }
        #endif
        return .dashboard
    }

    init() {
        #if DEBUG
        // `-switchTabAfter <秒>:<tab>`：启动 N 秒后自动切到某个 tab，复现"先在
        // 别的页面待一会儿再点过去"的路径（比如 Dashboard 预热完 map 数据再进
        // 地图）。给 xctrace 录 Time Profiler 用，真机上没法远程点 tab。
        if let spec = Self.debugArgument("-switchTabAfter") {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let secs = Double(parts[0]),
               let tab = AppTab(rawValue: parts[1]) {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(secs))
                    self?.selectedTab = tab
                }
            }
        }
        #endif
    }

    #if DEBUG
    private static func debugArgument(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    #endif
    var listingsPath: [ListingRoute] = []

    /// deep link 里的 listing id 是否可信。
    ///
    /// - 非空
    /// - ≤ 128 字符，防止超长 URL 撑爆后端 path
    /// - 只允许字母数字 / `-` / `_` —— 各平台的 listing id 都在这个集合里，
    ///   挡掉路径穿越 / 控制字符 / URL 编码注入
    ///
    /// 抽成一处：``openListing`` 与 ``openMap`` 都要验，两份写法迟早分叉，
    /// 而分叉的那一半就是没人看守的那个入口。
    /// `nonisolated`：纯函数，不碰任何状态。不标的话它会继承 @MainActor，
    /// 想在非主线程（比如同步的单元测试）校验一个 id 都得 await。
    nonisolated static func isValidListingID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// 从**浏览房源的某个视图内部**（列表行、日历条目、地图弹卡）打开详情。
    ///
    /// 和 ``openListing(id:titleHint:)`` 的区别是「从哪来」：那个是给 deep link
    /// 和通知用的，人不在 App 里，所以它会切 tab、切模式、把栈清成一层。而这个
    /// 是人已经站在日历或地图上点了一条——**不能换掉他脚下那一屏**。
    ///
    /// 原先这两处各写了一个 `if UIDevice.current.userInterfaceIdiom == .pad`，
    /// 走的是 `openListing`。在**窄窗口的 iPad**（竖屏 834pt、分屏、台前调度）
    /// 上那是错的：三个视图此时共用 Browse 这一个 tab，而 `openListing` 会把
    /// `selectedBrowseMode` 写成 `.list`——从日历点进一套房、按返回，人落在
    /// 列表里，日历没了。iPhone 走的是另一个分支所以一直正常。
    ///
    /// 判据换成 ``usesCompactTabs``：窄窗口就往当前这个栈上推一层，宽窗口下
    /// Listings 是独立 tab、详情本来就归它，才走 `openListing`。
    func showListing(id: String, titleHint: String? = nil) {
        guard Self.isValidListingID(id) else { return }
        if usesCompactTabs {
            listingsPath.append(.byId(id, titleHint: titleHint))
        } else {
            openListing(id: id, titleHint: titleHint)
        }
    }

    /// 由 deep link / 通知点击调用：切到 List 视图并 push 详情。
    /// 多次连点不重复 push 同一条；切换 tab 顺手清空已有 path。
    func openListing(id: String, titleHint: String? = nil) {
        guard Self.isValidListingID(id) else { return }

        selectedTab = .listings
        selectedBrowseMode = .list
        listingsPath = [.byId(id, titleHint: titleHint)]
    }

    /// 切到地图并聚焦某一套房源。
    ///
    /// 房源详情页的「在地图上查看」和 `h2smonitor://map/<id>` 都走这里。
    /// `.map` 这个 tab 只在 iPad 存在；iPhone 上 ``MainTabView.normalizeSelection``
    /// 会把它翻译成 `.browse` + `.map` 模式，所以两种设备都设同一个值就行。
    ///
    /// 实际的定位由 ``MapStore.focus(on:)`` 完成——那套房可能超出 14 天新鲜度
    /// 窗口、或被用户自己的 listing_filter 排除，此时要走 `/map/locate` 兜底
    /// 并说明是哪一种「看不到」。
    func openMap(focusing id: String) {
        guard Self.isValidListingID(id) else { return }
        pendingMapFocusID = id
        // **必须清空导航栈**。MapView 是 BrowseView 那个 NavigationStack 的
        // 根视图，而用户此刻正站在推上去的房源详情页上——只换根视图的话，详情页
        // 还盖在上面，点「在地图上查看」看起来毫无反应。
        //
        // 而且在 path 非空时换根视图，SwiftUI 的行为是未定义的。
        listingsPath = []
        selectedTab = .map
        selectedBrowseMode = .map
    }

    /// 待聚焦的房源 id。``MapView`` 出现时取走并清空——放在 coordinator 而不是
    /// 直接调 MapStore，是因为地图视图此刻可能还没挂载。
    var pendingMapFocusID: String?

    /// Logout / 401 auto-logout / 删号时清空全部导航状态。
    ///
    /// 为什么必须显式调：NavigationCoordinator 是 @Observable 单例，
    /// 跨 login/logout 一直存活在内存里。如果不重置，下个用户登入时
    /// 会看到上个用户最后停留的 tab + listings 详情页（残留 listingsPath
    /// 里的 ListingRoute），既诡异又可能泄露上一会话的房源 id。
    ///
    /// 由 ``FlatRadarApp`` 监听 ``AuthStore.isAuthenticated`` 切到 false
    /// 时统一调用，覆盖手动 logout、401 自动 logout、deleteAccount 三种路径。
    func reset() {
        selectedTab = .dashboard
        selectedBrowseMode = .list
        listingsPath = []
        pendingMapFocusID = nil
    }
}

/// Listings NavigationStack 的路由对象。
///
/// 两种打开方式：
/// - ``known(Listing)``：列表里点行，已有完整 Listing 数据
/// - ``byId(String)``：从 deep link 来，只有 id，详情页自己 fetch
enum ListingRoute: Hashable, Sendable {
    case known(Listing)
    case byId(String, titleHint: String?)
}
