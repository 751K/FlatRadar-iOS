import SwiftUI
import WidgetKit

/// iOS 主屏 / 锁屏小组件的入口。
///
/// 界面和 Mac 那边**是同一份代码**（`FlatRadarWidgets/`，两个 extension target
/// 同步同一个目录）。设计稿 4a 和 4b 画的就是同一套东西的两端：同样的层级、
/// 同样的文案、同样的色板，差别只有几个尺寸和一处标题缩写，在代码里是
/// `#if os(iOS)`。各写一份的话，下一次改配色就要改两遍，而漏掉一遍不会有任何
/// 东西报错——这一轮已经因为「同一句话两个写法」抓到三处了。
///
/// 这边**没有日历那一格**：设计稿的 iOS 部分只有这两格。Mac 那格日历是上一轮
/// 「是不是还可以做日历 base 的」的答案，不是稿子的一部分。
@main
struct FlatRadarWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        UnreadWidget()
    }
}
