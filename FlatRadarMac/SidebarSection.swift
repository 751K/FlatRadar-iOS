import SwiftUI

/// 侧栏的四个主条目。
///
/// 这是 Mac 版取代 iOS `MainTabView` 的东西，而且**简单得多**。
/// iOS 那边有一整套「920pt 门槛 + `visibleTab` 归一化」的复杂度，起因是 tab bar
/// 放不下六个条目时要把 Listings / Map / Calendar 折叠进 Browse，于是「当前 tab」
/// 可能指向一个已经不可见的 tab（iPad 转屏那一帧直接 abort）。
///
/// 侧栏没有这个问题：它可以折叠，但条目不会因为窗口变窄而消失。
/// 所以这里就是一个普通的枚举，没有归一化、没有门槛。
enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case listings
    case map
    case calendar
    case alerts
    case stats

    var id: String { rawValue }

    var label: String {
        switch self {
        case .listings: return "Listings"
        case .map:      return "Map"
        case .calendar: return "Calendar"
        case .alerts:   return "Alerts"
        case .stats:    return "Stats"
        }
    }

    var systemImage: String {
        switch self {
        case .listings: return "list.bullet"
        case .map:      return "map"
        case .calendar: return "calendar"
        case .alerts:   return "bell"
        case .stats:    return "chart.bar"
        }
    }
}
