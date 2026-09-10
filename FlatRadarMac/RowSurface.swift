import SwiftUI

/// 一行的**选中态和悬停态**长什么样。全 App 只有这一份配方。
///
/// 原本是 `ListingTable.swift` 里的一个 `private` 类型。通知屏也要同一套观感，
/// 与其抄一遍，不如提出来——「行是怎么被选中的」是个设计决定，两处各写一份
/// 迟早会漂移（改了列表忘了通知，或者反过来）。
///
/// 两种状态是**互斥**的两条分支，不是叠加
/// -----------------------------------
/// 选中走液态玻璃，悬停走「白底 + 投影」。已选中的行再悬停不叠效果：
/// 玻璃本身已经把那一行从背景里抬起来了，再加一层投影只会糊。
///
/// 为什么悬停靠**投影**而不是底色
/// ---------------------------
/// 设计稿 t3 的原话是「整行浮起（白底 + 深色投影），不加边框，与去线规则一致」。
/// 浅色下内容区本来就是白的，所以真正在传达"浮起"的是投影，底色只是把行和
/// 背景切开。深色下反过来：投影看不见，只能靠比背景亮一档（见 ``Theme/rowHover``）。
/// CSS 的 `0 3px 12px` 换算成 SwiftUI 是 radius 6 / y 3。
struct RowSurface: ViewModifier {

    let isSelected: Bool
    let isHovered: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content
                .glassEffect(.regular.tint(Theme.selectionFill),
                             in: RoundedRectangle(cornerRadius: 7))
        } else {
            content
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered ? Theme.rowHover : .clear))
                .shadow(color: .black.opacity(isHovered ? 0.15 : 0),
                        radius: 6, x: 0, y: 3)
        }
    }
}
