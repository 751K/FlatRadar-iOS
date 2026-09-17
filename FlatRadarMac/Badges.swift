import SwiftUI
import FlatRadarCore

/// Mac 端的三个视觉原子：状态胶囊、平台徽章、能效字母。
///
/// 尺寸按 docs/DESIGN.md §6 的换算表：iOS 那套 11pt bold 状态文字、9/10/12pt
/// 平台徽章是按 17pt 正文定的，Mac 正文是 13pt，所以整体降一档。
/// **9pt 不再往下缩**——那已经是可读下限。
///
/// 为什么不直接复用 iOS 的 `PlatformBadge`
/// -------------------------------------
/// 它在 `FlatRadar` 这个 iOS app target 里，不在包里，Mac 编不到。挪进包是可以的，
/// 但那要连着尺寸体系一起想（同一个组件在两端要有两套尺寸），属于单独一件事。
/// 现在两份的**颜色和缩写都来自包里的 `Platform`**，会漂移的只有内边距。

// MARK: - 状态标记

/// 一颗立起来的方块。菜单栏面板的房源行、以及菜单栏图标旁边那颗未读点。
///
/// 为什么这两处不用 ``StatusPill`` 里那个圆点
/// ---------------------------------------
/// 胶囊那个圆点**旁边有字**（`● Book`），形状不需要自己承担区分的活。面板那一行
/// 只有 6pt 的标记，没有文字跟着——在一排系统菜单栏图标（全是圆的）和一列房源
/// 里，菱形是唯一一眼能认出"这是 FlatRadar 在说状态"的形状。桌面小组件的
/// NEWEST 行出于同一个理由也是菱形，三处是同一个决定。
///
/// 用 `Path` 而不是 `.rotationEffect(.degrees(45))`：旋转改的是渲染，布局框还是
/// 原来那个正方形，6pt 的方块转完对角线是 8.5pt，会顶到相邻元素。
struct Diamond: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

// MARK: - 状态胶囊

/// 圆点 + 文字 + 同色淡底。全 App 同一个配方，见 docs/DESIGN.md §3.3。
struct StatusPill: View {

    /// 「增加对比度」开着时把底色从 13% 提到 20% 并补一圈同色描边，
    /// 让**形状轮廓**也参与传达，不再纯靠颜色差。设计稿的 `pill()` 就是这个配方，
    /// 和 iOS 端 `ListingRow.statusBadge` 也一致。
    @Environment(\.colorSchemeContrast) private var contrast

    let status: String?
    var compact = false

    var body: some View {
        let kind = ListingStatus.from(status)
        let color = Theme.statusColor(kind)
        // 认不出的状态显示**后端给的原始串**，不是「Unknown status」——
        // 用户至少能看见平台到底说了什么。和后端 status_capsule 的兜底一致。
        let label = Theme.shortStatusLabel(kind) ?? (status ?? "—")

        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(color.opacity(contrast == .increased ? 0.20 : 0.13), in: Capsule())
        .overlay {
            if contrast == .increased {
                Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

// MARK: - 平台徽章

/// `H2S` / `OD` / `XR` …… 颜色和缩写都取自包里的 ``Platform``，
/// 保证同一个平台在表格、详情、将来的地图上是同一个颜色。
struct PlatformBadge: View {

    @Environment(\.colorSchemeContrast) private var contrast

    let source: String?

    var body: some View {
        // 用 Mac 自己那套压暗过的平台色，不是包里给 iOS 的系统色——
        // 9pt 的字要更深才读得出，而且系统蓝离 Reserved 的蓝太近。见 ``Theme/platform(_:)``。
        let color = Theme.platform(source)
        Text(Platform.shortName(source))
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .tracking(0.5)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(contrast == .increased ? 0.24 : 0.16), in: Capsule())
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1)
                }
            }
            .foregroundStyle(color)
            // 缩写对读屏软件没意义，念全名。
            .accessibilityLabel("Platform \(Platform.displayName(source))")
    }
}

// MARK: - 能效字母

/// A 档上色，B 及以下用正文色，缺失显示 `—`。着色规则见 ``EnergyStyle``。
struct EnergyLabel: View {

    let text: String?

    var body: some View {
        let value = (text?.isEmpty == false) ? text! : "—"
        let color = EnergyStyle.color(text)
        Text(value)
            // 和旁边的 City / Type 同为次级数据（`.callout` = 12pt），靠**字重**
            // 而不是字号把它挑出来：A 档上色之后光靠颜色在这个字号上不够。
            //
            // 注释原先两处都写的 11pt，是照设计稿的 px 抄的，和代码对不上——
            // 实测 `.callout` 是 12pt，City / Type 也是 12pt。
            .font(.callout.weight(.semibold))
            .foregroundStyle(color ?? .secondary)
    }
}

// MARK: - 「标签 值」一行

/// 详情面板里的一行：标签左对齐固定宽，值**右对齐**。
///
/// 右对齐是设计稿定的（`label 78px / 值 flex:1 text-align:right`）：八行数值贴着
/// 同一条右边线，竖着扫的时候不用逐行找。左右各自贴边也让「标签」和「值」
/// 分成两个视觉列，不需要中间那条点线或下划线——t2「去线」的规则。
///
/// 值缺失时显示 `—`，**不留空**：留空看不出是「没有」还是「没加载」。
struct LabeledRow: View {

    let label: String
    let value: String?
    var valueColor: Color?
    var mono = false

    init(_ label: String, _ value: String?, color: Color? = nil, mono: Bool = false) {
        self.label = label
        self.value = (value?.isEmpty == true) ? nil : value
        self.valueColor = color
        self.mono = mono
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value ?? "—")
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(valueColor ?? .primary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
        .frame(height: 29)
    }
}
