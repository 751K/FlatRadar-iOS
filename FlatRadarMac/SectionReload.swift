import SwiftUI

/// 「刷新」刷的是**眼前这一屏**。工具栏那个按钮和 ⌘R 走同一个。
///
/// 原先两处都写死成刷新房源列表：工具栏是 `model.reload()` + 共享摘要，⌘R 更只有
/// `model.reload()`。站在地图、日历、通知、统计任何一屏按刷新，重拉的都是一张
/// 看不见的表（代码审查 P2）。地图和日历第一次拉成功之后只在"还是空的"时才重取，
/// 于是这两屏除了重启 app 就没有任何办法看到新数据。
///
/// 做成一组闭包而不是在视图里 `switch`：各屏的 store 分散在窗口（地图、统计、
/// 房源）和应用级（日历、通知）两层，闭包在 `MainWindow` 里拼好；"哪一屏刷哪个"
/// 这条规则本身则能单独测。
struct SectionReloader {

    typealias Action = @MainActor @Sendable () async -> Void

    var listings: Action
    var map: Action
    var calendar: Action
    var alerts: Action
    var stats: Action

    /// 侧栏计数、菜单栏、桌面小组件那一层（``AppFeed/refreshShared(auth:forPanel:)``）。
    ///
    /// **每一屏刷新都顺带过一遍**：侧栏上那几个数字在哪一屏都显示着，用户按刷新时
    /// 眼睛看到的也包括它们。这也是原先工具栏按钮已有的行为，保留。
    var shared: Action

    /// 这一屏自己的那份数据。
    func own(_ section: SidebarSection) -> Action {
        switch section {
        case .listings: listings
        case .map:      map
        case .calendar: calendar
        case .alerts:   alerts
        case .stats:    stats
        }
    }

    /// 两份一起发，互不等待：摘要慢一点不该拖住眼前这一屏。
    func reload(_ section: SidebarSection) async {
        async let mine: Void = own(section)()
        async let common: Void = shared()
        _ = await (mine, common)
    }
}

/// 交给菜单命令的那一份：当前窗口、当前这一屏的刷新。
///
/// 和 ``FocusedValues/browseModel`` 同一个路子——`Commands` 在场景层，碰不到窗口里
/// 的 store，只能由窗口把"刷新我"这个动作递上去。
struct SectionReloadAction {
    let section: SidebarSection
    /// 这一屏正在取数。按钮和菜单项据此置灰，免得连按叠出好几个同样的请求。
    let isLoading: Bool
    let run: @MainActor () async -> Void

    var title: String { "Reload \(section.label)" }
}

extension FocusedValues {
    @Entry var sectionReload: SectionReloadAction?
}
