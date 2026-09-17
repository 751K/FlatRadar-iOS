import SwiftUI
import WidgetKit

/// 桌面小组件的入口。
///
/// 现在只有一格（``StatusWidget``），但仍然写成 `WidgetBundle` 而不是把
/// `@main` 挂在那一个 widget 上：加第二格时前者只是多一行，后者要改入口的形状。
@main
struct FlatRadarMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
    }
}
