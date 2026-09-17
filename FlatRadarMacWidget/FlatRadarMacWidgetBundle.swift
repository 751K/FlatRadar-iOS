import SwiftUI
import WidgetKit

/// 桌面小组件的入口。
///
/// 两格，回答两个不同的问题：``StatusWidget`` 答「今天有什么新的」，
/// ``CalendarWidget`` 答「下次什么时候有房」。两格读的是**同一份**共享快照
/// （``WidgetSnapshot``），所以它们的数字不可能互相矛盾。
@main
struct FlatRadarMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        CalendarWidget()
    }
}
