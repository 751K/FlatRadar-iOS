import SwiftUI
import FlatRadarCore

/// 平台徽标（"H2S" / "OC" / …）——**全 App 唯一一份**。
///
/// 收拢之前，地图弹卡、日历行、房源详情各有一份 `sourceBadge` + `sourceColor`，
/// 三份完全一样，而且都只认三个平台：
///
/// ```swift
/// case "ourdomain": return .purple
/// case "xior":      return .teal
/// default:          return .blue      // ← OurCampus / Magis / SE / Plaza 全在这
/// ```
///
/// 四个平台和 Holland2Stay 同色，等于颜色没有承载任何信息。颜色现在按平台取
/// （见 ``Platform.color``），一个平台在任何页面都是同一个颜色。
///
/// 三处原本只有字号和内边距不同，用 ``Size`` 表达，其余一律共用。
struct PlatformBadge: View {

    enum Size {
        /// 日历行等信息密度高的地方。
        case small
        /// 地图弹卡。
        case medium
        /// 房源详情页头部。
        case large

        /// 字号走**文字样式**不是裸数字，这样才跟随系统字号。
        ///
        /// small / medium 原先是 9pt 和 10pt——`caption-2`（11pt）是设计系统
        /// 的地板，比它小的字号不在这套系统里，而且裸尺寸完全不随「辅助功能 →
        /// 字体大小」变化。两者现在都落到 `.caption2`，差异靠内边距表达；
        /// 它们本来也只差 1pt，视觉上分不出来。
        var style: Font.TextStyle {
            switch self {
            case .small, .medium: return .caption2
            // caption（12pt）而不是 caption2：用它的两处（地图弹卡、房源详情页
            // 头部）旁边都是 body，11pt 的徽标在那个语境里显小。
            case .large: return .caption
            }
        }
        var hPadding: CGFloat {
            switch self {
            case .small: return 5
            case .medium: return 6
            case .large: return 8
            }
        }
        var vPadding: CGFloat {
            switch self {
            case .small: return 2
            case .medium: return 2
            case .large: return 4
            }
        }
    }

    @Environment(\.colorScheme) private var scheme

    let source: String?
    var size: Size = .medium

    var body: some View {
        let color = Platform.color(source)
        Text(Platform.shortName(source))
            .font(.system(size.style, design: .monospaced, weight: .heavy))
            .padding(.horizontal, size.hPadding)
            .padding(.vertical, size.vPadding)
            .background(color.opacity(0.16), in: Capsule())
            // 字色不能就是底色——理由和换算见 Color.onTint(in:)。
            .foregroundStyle(color.onTint(in: scheme))
            // 缩写对读屏软件没有意义，念全名。
            .accessibilityLabel("Platform \(Platform.displayName(source))")
    }
}
