import SwiftUI
import WidgetKit

/// 桌面小组件的入口。
///
/// 三格，各回答一个问题——设计稿那句「小号只回答一个问题」是按格分的，不是
/// 按尺寸分的：``StatusWidget`` 答「今天有什么新的」，``UnreadWidget`` 答
/// 「有多少我还没看」，``CalendarWidget`` 答「下次什么时候有房」。
///
/// 三格读的是**同一份**共享快照（``WidgetSnapshot``），所以它们的数字不可能
/// 互相矛盾。
@main
struct FlatRadarMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        UnreadWidget()
        CalendarWidget()
    }
}
