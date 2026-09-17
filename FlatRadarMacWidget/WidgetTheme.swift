import SwiftUI

/// 设计稿 `FlatRadar Widgets.dc.html` 的色值和排版原子。
///
/// 为什么不复用 `Theme`
/// ------------------
/// 够不到：`Theme` 在 app target 里，扩展是另一个 target。但**也不该复用**——
/// `Theme` 顶上那条规矩是「不选色相」（七个平台色 + 五个状态色已经把色相空间占满，
/// 任何有色相的强调色都会在同一行里撞上），而那条规矩是给**表格**定的：
/// 一行里同时有平台徽章、状态胶囊、能效标签时，再加一个色相就没法读了。
/// 小组件那一格里一个平台色都没有，所以设计稿在这里选了暖纸底 + 一个红强调，
/// 这不是违反规矩，是规矩的前提不成立。
///
/// 为什么不用 `NSColor(name:dynamicProvider:)`
/// -----------------------------------------
/// `Theme` 里那个 `Color(light:dark:)` 走的是动态 provider，而那个闭包会被
/// AppKit 在非主线程上调用——`Theme` 自己的注释里写着「iOS 那边同一份写法实测
/// 崩过」「Mac 这边目前没崩到，纯属运气」。小组件渲染跑在扩展进程的另一套时序上，
/// 不想再赌一次。这里改成**显式按 `colorScheme` 取一份**：视图从环境里读明暗，
/// 拿到一个纯值结构体，没有闭包、没有隔离问题。
struct WidgetPalette {

    let paper: Color        // 卡片底
    let ink: Color          // 主文字
    let muted: Color        // 次要文字
    let accent: Color       // 红：新上架 / 未读
    let up: Color           // 绿：涨
    let live: Color         // 绿点：抓取在线
    let status: Color       // 蓝：状态变化
    let lottery: Color      // 棕：抽签
    /// 填充块的底色。设计稿的分组「靠填充差而不是描边」，这是那个填充。
    let fill: Color
    /// 柱子的常态色。
    let barIdle: Color
    /// NEWEST 行的隔行底色（深 / 浅）。
    let rowA: Color
    let rowB: Color
    /// 非首行那个菱形的颜色。
    let pinIdle: Color

    static func resolve(_ scheme: ColorScheme) -> WidgetPalette {
        scheme == .dark ? .dark : .light
    }

    /// 浅色。取自设计稿 4a（macOS 通知中心那一栏），逐个 hex 照搬。
    static let light = WidgetPalette(
        paper:   Color(hex: 0xFBFAF7),
        ink:     Color(hex: 0x1B2B38),
        muted:   Color(hex: 0x54504A),
        accent:  Color(hex: 0xAD3E39),
        up:      Color(hex: 0x148C46),
        live:    Color(hex: 0x34C759),
        status:  Color(hex: 0x3B82F6),
        lottery: Color(hex: 0x9F7646),
        fill:    Color(hex: 0x293B49).opacity(0.055),
        barIdle: Color(hex: 0x293B49).opacity(0.20),
        rowA:    Color(hex: 0x293B49).opacity(0.07),
        rowB:    Color(hex: 0x293B49).opacity(0.035),
        pinIdle: Color(hex: 0x293B49).opacity(0.30))

    /// 深色。
    ///
    /// **设计稿只画了三个深色值**——4b 那张深色 UNREAD 卡给了底 `#16212B`、
    /// 字 `#F3F0E8`、次要 `#A9B3BC`，以及红 `#E2706B` / 蓝 `#6AA6F5` /
    /// 棕 `#C99C68`。剩下的是按**同一个位移**推出来的，这里说清楚哪些是稿子上
    /// 有的、哪些是推的，免得下次有人把推出来的当成规范：
    ///
    /// | | 来源 |
    /// |---|---|
    /// | paper / ink / muted / accent / status / lottery | 稿子上有 |
    /// | up（绿） | 按红 `#AD3E39 → #E2706B` 那个提亮幅度推的 |
    /// | live（绿点） | Apple 自己的 systemGreen 深色配对 `#30D158` |
    /// | fill / barIdle / rowA / rowB / pinIdle | 和浅色一样的构造法：ink 压低透明度 |
    static let dark = WidgetPalette(
        paper:   Color(hex: 0x16212B),
        ink:     Color(hex: 0xF3F0E8),
        muted:   Color(hex: 0xA9B3BC),
        accent:  Color(hex: 0xE2706B),
        up:      Color(hex: 0x4FC585),
        live:    Color(hex: 0x30D158),
        status:  Color(hex: 0x6AA6F5),
        lottery: Color(hex: 0xC99C68),
        fill:    Color(hex: 0xF3F0E8).opacity(0.08),
        barIdle: Color(hex: 0xF3F0E8).opacity(0.22),
        rowA:    Color(hex: 0xF3F0E8).opacity(0.09),
        rowB:    Color(hex: 0xF3F0E8).opacity(0.045),
        pinIdle: Color(hex: 0xF3F0E8).opacity(0.35))
}

nonisolated extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = WidgetPalette.light
}

extension EnvironmentValues {
    var palette: WidgetPalette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - 排版原子

/// 段标题：等宽、加粗、字距拉开、全大写。
///
/// 大写是**排版**不是文案——传进来的仍然是 `StatusWording` 里那句正常大小写的话
/// （`New today`），大写由 `.textCase` 做。存大写的话，同一句话在统计带和小组件
/// 就成了两个字符串常量，而这个仓库刚因为那种事抓到过两处漂移。
struct SectionLabel: View {
    let text: String
    @Environment(\.palette) private var palette
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(palette.muted)
            .lineLimit(1)
    }
}

/// 红菱形＝新上架。设计稿里这个形状只有这一个意思。
struct Diamond: View {
    var color: Color
    var size: CGFloat = 6
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(45))
            .frame(width: size * 1.42, height: size * 1.42)
    }
}

/// 空心圈＝未读。和实心菱形区分开：一个是"来了新东西"，一个是"你还没看"。
struct Ring: View {
    var color: Color
    var size: CGFloat = 7
    var body: some View {
        Circle().strokeBorder(color, lineWidth: 2).frame(width: size, height: size)
    }
}

struct Dot: View {
    var color: Color
    var size: CGFloat = 6
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

/// 展示数字。等宽 + tabular，字距按字号比例收——设计稿 46pt 配 -2，比例 -0.043。
struct DisplayNumber: View {
    let text: String
    var size: CGFloat
    var dimmed = false
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .monospaced))
            .tracking(size * -0.043)
            .monospacedDigit()
            .lineLimit(1)
            // 五位数在 170pt 宽的卡里会顶到边。缩而不是截：一个被截掉最后一位的
            // 数字是**错的**，小一号的还是对的。
            .minimumScaleFactor(0.5)
            .foregroundStyle(dimmed ? palette.muted : palette.ink)
    }
}
