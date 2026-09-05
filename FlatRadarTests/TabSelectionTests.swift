import XCTest
@testable import FlatRadar

/// TabView 的 selection 永远不能指向一个隐藏的 tab。
///
/// 守的是一次真实崩溃
/// ------------------
/// iPad Pro 11 寸竖屏 834pt、横屏 1194pt，转屏正好跨过 `shouldUseCompactTabs`
/// 的 920。翻转那一瞬间 `.browse` 从可见变隐藏，而 `coord.selectedTab` 要等
/// `.onChange(of:)` 才被改写——那发生在视图更新之后。中间那一帧 selection 指着
/// 一个 `.hidden(true)` 的 tab，iOS 18 的 TabView 直接 abort，调用栈停在
/// `__pthread_kill` 上，看不出任何线索。
///
/// 合并成一个 TabView 之前不存在这个窗口：compact / wide 是两个各自完整的
/// TabView，切换时整个被换掉。合并之后「tab 集合变化」和「selection 变化」成了
/// 两个独立的时刻，中间有了缝。
///
/// 修法是让 selection 变成派生值——`visibleTab` 现算，缝就不存在。这批测试
/// 钉住那个函数，尤其是最后那条不变式：**它的返回值必须永远落在当前形态的可见
/// 集合里**。那条不变式一破，App 就会在转屏时崩，而崩溃现场不会告诉你为什么。
final class TabSelectionTests: XCTestCase {

    /// 窄形态下真正存在于 TabView 里的 tab。
    /// Listings / Map / Calendar 收在 Browse 里，各自的 tab 是 `.hidden(true)`。
    private static let visibleWhenCompact: Set<AppTab> =
        [.dashboard, .browse, .notifications, .settings]

    /// 宽形态：三个展开，Browse 反过来被隐藏。
    private static let visibleWhenWide: Set<AppTab> =
        [.dashboard, .listings, .map, .calendar, .notifications, .settings]

    // MARK: - 窄形态

    func test_compact_folds_the_three_browse_modes_into_browse() {
        for tab in [AppTab.listings, .map, .calendar] {
            XCTAssertEqual(
                MainTabView.visibleTab(tab, compact: true, browseMode: .list),
                .browse,
                "\(tab) 在窄形态下是隐藏的，必须映射成 Browse")
        }
    }

    func test_compact_leaves_the_other_tabs_alone() {
        for tab in [AppTab.dashboard, .browse, .notifications, .settings] {
            XCTAssertEqual(
                MainTabView.visibleTab(tab, compact: true, browseMode: .map),
                tab)
        }
    }

    // MARK: - 宽形态

    func test_wide_expands_browse_according_to_the_current_mode() {
        let expected: [BrowseMode: AppTab] = [
            .list: .listings, .map: .map, .calendar: .calendar,
        ]
        for (mode, tab) in expected {
            XCTAssertEqual(
                MainTabView.visibleTab(.browse, compact: false, browseMode: mode),
                tab,
                "宽形态下 Browse 是隐藏的，要按 browseMode 展开到对应的那一个")
        }
    }

    func test_wide_leaves_the_other_tabs_alone() {
        for tab in [AppTab.dashboard, .listings, .map, .calendar, .notifications, .settings] {
            XCTAssertEqual(
                MainTabView.visibleTab(tab, compact: false, browseMode: .list),
                tab)
        }
    }

    // MARK: - 不变式

    /// 这条是重点：**任何输入组合下，输出都必须是当前形态里可见的 tab。**
    ///
    /// 前面几条测的是具体映射，改需求时它们本来就该跟着改。这一条不是——它破了
    /// 就意味着有一个输入能让 selection 落在隐藏 tab 上，而那是崩溃本身。
    func test_the_result_is_always_a_visible_tab() {
        let allTabs: [AppTab] =
            [.dashboard, .browse, .listings, .map, .calendar, .notifications, .settings]

        for tab in allTabs {
            for mode in BrowseMode.allCases {
                for (compact, visible) in [(true, Self.visibleWhenCompact),
                                           (false, Self.visibleWhenWide)] {
                    let result = MainTabView.visibleTab(tab, compact: compact,
                                                        browseMode: mode)
                    XCTAssertTrue(
                        visible.contains(result),
                        "visibleTab(\(tab), compact: \(compact), browseMode: \(mode)) "
                        + "返回了 \(result)，而它在这个形态下是隐藏的。"
                        + "selection 指向隐藏 tab 会让 TabView 在转屏时 abort。")
                }
            }
        }
    }

    /// 幂等：把结果再喂回去应当不变。转屏来回切时这个函数会被反复调用。
    func test_normalizing_twice_changes_nothing() {
        let allTabs: [AppTab] =
            [.dashboard, .browse, .listings, .map, .calendar, .notifications, .settings]

        for tab in allTabs {
            for mode in BrowseMode.allCases {
                for compact in [true, false] {
                    let once = MainTabView.visibleTab(tab, compact: compact, browseMode: mode)
                    let twice = MainTabView.visibleTab(once, compact: compact, browseMode: mode)
                    XCTAssertEqual(once, twice, "\(tab) / compact=\(compact) / \(mode)")
                }
            }
        }
    }
}
