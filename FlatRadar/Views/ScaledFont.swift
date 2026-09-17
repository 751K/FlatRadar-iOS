import SwiftUI

/// 让一个**不落在标准字阶上**的字号也跟随系统字号。
///
/// 为什么需要它
/// ------------
/// 设计系统那条规矩是「每一段文字都用字阶，不写裸数字」——因为 `.font(.system(size:))`
/// 完全不理会「辅助功能 → 显示与文字大小」里的设置，用户把字调到最大，那段文字
/// 纹丝不动。绝大多数地方照着规矩换成 `.caption2` / `.body` 这类就完了。
///
/// 但有一类换不了：**登录屏和几个展示型大数字**。它们的尺寸是照着设计稿一格一格
/// 量出来的（27 / 38 / 40、58、26……），而最大的标准档 `largeTitle` 才 34pt——
/// 硬套字阶等于把设计稿改了。
///
/// `@ScaledMetric` 就是 Apple 给这种情况的出口：保住原始数值，同时让它按
/// `relativeTo:` 那一档的比例跟着系统字号缩放。这个修饰符只是把它包成一行能用的
/// 写法——`@ScaledMetric` 是属性包装器，必须挂在某个 `View` 上，没法在
/// `LoginMetrics` 那种纯数据结构里直接用。
///
/// 用法
/// ----
/// ```swift
/// Text("FlatRadar").scaledFont(m.wordmark, relativeTo: .title, weight: .bold)
/// ```
///
/// `relativeTo:` 选哪一档不是随便填的：它决定缩放**比例**。正文一档的文字选
/// `.body`，大标题选 `.largeTitle`，小字注解选 `.caption2`——选错了不会出错，
/// 但放大时各段文字之间的比例会走样。
struct ScaledFont: ViewModifier {

    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat,
         relativeTo textStyle: Font.TextStyle,
         weight: Font.Weight,
         design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// 见 ``ScaledFont``。
    func scaledFont(_ size: CGFloat,
                    relativeTo textStyle: Font.TextStyle = .body,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, relativeTo: textStyle,
                            weight: weight, design: design))
    }
}
