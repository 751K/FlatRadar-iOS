import SwiftUI
import FlatRadarCore

/// Mac 端的设计 token，取自设计稿 `FlatRadar Mac - Listings.dc.html` 的 `TH` 表。
///
/// 为什么这些值不放进 `FlatRadarCore`
/// --------------------------------
/// 包里那 8 个语义色（status / energy）是**两端共用的业务语义**，改一处两端跟着变，
/// 那是对的。这里的东西不一样：强调色、选中填充、平台色的具体色值，都是
/// **Mac 这一端的视觉决定**，iOS 有它自己已经用熟的一套。混进包里会让「改 Mac 的
/// 配色」变成「顺手改了 iOS」。
enum Theme {

    // MARK: - 强调色：ink，没有色相

    /// 设计稿 t1 的三个前置决定之二，原文：
    ///
    /// > 七个平台色 + 五个状态色已经把色相空间占满，任何有色相的强调色都会在
    /// > 同一行里撞上（系统蓝会同时撞 H2S 蓝和 Reserved 蓝）。ink 与 Occupied 灰的
    /// > 明度差足够大，读作结构墨色而非状态色。
    ///
    /// 这正是 docs/DESIGN.md §8 里我提的那个待定项的答案，而且比我给的两个选项
    /// （换强调色色相 / 换 H2S 平台色）都好：**不选色相**，冲突就不存在了。
    ///
    /// 代价要说清楚：主按钮和选中态失去了「品牌色」，整个界面是灰阶 + 数据本身的
    /// 颜色。对一个**表格工具**这是对的——有颜色的地方就是有信息的地方。
    static let ink = Color(light: 0x1C1C1E, dark: 0xF2F2F7)

    /// 选中行的底色。
    ///
    /// 设计稿 t1 决定之三：**不用实心强调色填充 + 白字**——那会把整行的状态色和
    /// 能效色一起压掉，而那两列恰好是这张表最有信息量的地方。改成中性填充。
    static let selectionFill = Color(light: 0xE7E7EA, dark: 0x333336)

    /// 侧栏 / inspector 的底。内容区是纯白，靠**明度差**分栏，不画 1px 描边——
    /// 这是 t2「去线留白」的核心手法。
    static let chrome = Color(light: 0xF4F4F6, dark: 0x252527)

    /// 登录屏左栏那块暖底。设计稿的 `#F3F0E8`。
    ///
    /// 全 App 唯一一处**暖色**，其余都是中性灰。它只出现在登录屏——那一屏没有
    /// 任何数据，暖底是在说「这里不是工作区」；进了主窗口就再也不出现，
    /// 免得和七个平台色、五个状态色抢注意力。
    ///
    /// 两个值都**必须**跟着 app 图标走，不能自己挑：
    ///
    /// - 浅色 `#F3F0E8` 正是 `2-windows.svg` 里窗户的填充色。插画的窗户是
    ///   拿背景色"抠"出来的——底色一旦偏一点，窗户就会显出一圈边。
    /// - 深色取自 `AppIcon.icon/icon.json` 的 dark fill
    ///   （display-p3 0.0667 0.1098 0.1608）。深色版插画的窗户改成了点亮的
    ///   暖黄 `#F5D99B`，不再依赖背景色，但房子和水面的配色是照着这个
    ///   深蓝底调的，换个底就不成立了。
    static let pitchBackground = Color(light: 0xF3F0E8, dark: 0x0E1C29)

    /// 鼠标悬停时那一行的底色。
    ///
    /// 设计稿 t3：「整行浮起（白底 + 深色投影），不加边框，与去线规则一致」。
    /// 浅色下内容区本来就是白的，所以**真正在传达"浮起"的是投影**，底色只是
    /// 把行和背景切开。深色下反过来：投影看不见，只能靠比背景亮一档。
    static let rowHover = Color(light: 0xFFFFFF, dark: 0x2C2C2E)

    // MARK: - 字号
    //
    // **一律用 SwiftUI 的语义字号，不写死磅值。**
    //
    // macOS 的字阶（HIG「Typography」，和本机 `NSFont.preferredFont` 实测一致）：
    //
    // | 样式 | 磅值 | 行高 | 强调字重 |
    // |---|---|---|---|
    // | largeTitle | 26 | 32 | Bold |
    // | title      | 22 | 26 | Bold |
    // | title2     | 17 | 22 | Bold |
    // | title3     | 15 | 20 | Semibold |
    // | headline   | 13 (Bold) | 16 | Heavy |
    // | body       | 13 | 16 | Semibold |
    // | callout    | 12 | 15 | Semibold |
    // | subheadline| 11 | 14 | Semibold |
    // | footnote   | 10 | 13 | Semibold |
    // | caption    | 10 | 13 | Medium |
    //
    // HIG 另外钉死两个数：**默认 13pt，最小 10pt**。控件字号 regular 13 /
    // small 11 / mini 9。
    //
    // 为什么这里要写这一段
    // ------------------
    // 第一版是照着设计稿的 HTML 逐个抄 px 值落成 pt 的（13 / 11.5 / 10.5 / 9 …）。
    // 那些数字是浏览器里的相对层级，不是 macOS 的字阶——抄过来之后有一半落在
    // **阶与阶之间**（10.5、11.5），另一半把该是正文的数据压到了 subheadline，
    // 整体就"小一号"。9pt 的平台徽章更是直接掉到 HIG 最小值以下。
    //
    // 现在的规则：
    // - 主数据（地址、价格、详情的值）→ `.body`
    // - 次级数据（城市、面积、房型、可入住）→ `.callout`
    // - 标签和 chrome（列头、分区标题、说明）→ `.subheadline`
    // - 最小的注脚（计数、出处、时间戳）→ `.caption`
    // - **文字不写 10pt 以下**；只有 SF Symbol 的装饰性字形可以（箭头、✕）
    //
    // 例外只有两个，都在 ``Badges``：状态胶囊 10–11pt、平台徽章 10pt。
    // 它们是胶囊里的短标签，不是成句的文字，压到下限是有意的。

    // MARK: - 平台色

    /// 设计稿给的是具体色值，不是 SwiftUI 系统色。
    ///
    /// 和 `FlatRadarCore.Platform.color` 的差别是**有意的**：那边用
    /// `.blue` / `.purple` / … 是 iOS 上沿用下来的，浅色模式下偏亮；这里整体压暗、
    /// 加饱和度，因为 Mac 上这个徽章只有 9pt，而且要和 Reserved 的 `#3B82F6`
    /// 在同一行里区分开——系统蓝 `#007AFF` 离得太近。
    ///
    /// 认不出的平台走 `Platform.color` 兜底（灰），不在这里编一个色。
    static func platform(_ source: String?) -> Color {
        switch Platform.shortName(source) {
        case "H2S": return Color(light: 0x0069D9, dark: 0x0A84FF)
        case "OD":  return Color(light: 0x9A3FC8, dark: 0xBF5AF2)
        case "OC":  return Color(light: 0x4B49C6, dark: 0x7D7BEE)
        case "XR":  return Color(light: 0x1B93A8, dark: 0x40C8E0)
        case "MG":  return Color(light: 0xE01E48, dark: 0xFF375F)
        case "SE":  return Color(light: 0xC86A00, dark: 0xFF9F0A)
        case "PZ":  return Color(light: 0x8A6A48, dark: 0xC09A72)
        default:    return Platform.color(source)
        }
    }

    // MARK: - 状态

    /// 表格里的短标签。
    ///
    /// 包里的 `ListingStatus.label` 是给 iOS 用的（"Direct book" / "Unknown status"），
    /// 那些串进了五种语言的本地化目录，不能为了 Mac 的列宽去改。
    ///
    /// 这四个短词**和后端 `jinja_filters.status_capsule` 用的是同一套**
    /// （Book / Lottery / Reserved / Occupied），网页端一直就是这么显示的。
    ///
    /// 认不出的状态返回 `nil`，由调用方显示**后端给的原始串**——也和
    /// `status_capsule` 的兜底一致（它 `return StatusCapsule(status or "", "secondary")`）。
    static func shortStatusLabel(_ status: ListingStatus) -> String? {
        switch status {
        case .book:     return "Book"
        case .lottery:  return "Lottery"
        case .reserved: return "Reserved"
        case .occupied: return "Occupied"
        case .other:    return nil
        }
    }

    /// 表格里认不出的状态用**灰色**，不是包里那个紫色。
    ///
    /// 设计稿 t3 写的是「紫色的 unmapped 一档取消」，我只在**表格**里照做，
    /// 理由是两边的顾虑不冲突：
    ///
    /// - 紫色那一档存在的理由（`ListingStatus` 注释里写着）是**地图筛选**——
    ///   把认不出的状态归进 occupied，它会跟着终态一起被默认隐藏，
    ///   于是新平台冒出的新状态从图上静默消失。
    /// - 但**列表没有默认隐藏任何东西**，行永远在那儿。这里紫色不解决任何问题，
    ///   只是多一个色相。后端和网页端在列表里也是灰色 + 原始串。
    ///
    /// 所以：`ListingStatus.other` 这个 case **必须留着**（地图 Phase 3 要用），
    /// 紫色 token 也留着，只是表格不用它。
    static func statusColor(_ status: ListingStatus) -> Color {
        status == .other ? .statusOccupied : status.color
    }
}

// MARK: - 十六进制

private extension Color {
    /// 设计稿给的是浅 / 深两个 hex，这里直接照搬，不再绕 Asset Catalog——
    /// 那 8 个语义色进 catalog 是因为**两端共用**，这些只有 Mac 用。
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
