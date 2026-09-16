import SwiftUI
import FlatRadarCore

/// 一套房源的**只读事实**：标题、徽章、八行「标签 值」、出处。
///
/// 为什么单独拆出来
/// ---------------
/// Phase 4 的独立详情窗口（``ListingWindow``）和右栏 inspector 要显示的是
/// **同一套事实**。原先这几段都是 `InspectorPane` 的私有方法，第二个用处一出现，
/// 摆在面前的就是"复制一份"——而这个代码库里已经吃过那个亏：`RowSurface` 的注释
/// 写着「只有这一个配方」，实际却漂成了三处各写各的。
///
/// 所以这里是**唯一**一份：改价格的写法、加一行事实、调标签宽度，两处一起变。
///
/// 这一层刻意**不认识 `BrowseModel`**。能进来的只有一个 `Listing`，
/// 于是它在任何上下文里都能用——右栏、独立窗口，将来的并排比较视图也一样。
/// 需要窗口状态的东西（钉住、比价、小地图缓存）留在各自的调用方。

// MARK: - 文本

/// 两处共用的文本口径。
///
/// 是 `enum` 命名空间而不是 `Listing` 的扩展：这些规则是**这个 app 的展示口径**，
/// 不是模型的属性，放进 `FlatRadarCore` 会让 iOS 端也继承一套它没要的规则。
nonisolated enum ListingText {

    /// `城市 · 楼盘`，去掉和房源名重复的部分。
    ///
    /// 整段实现在包里的 ``PlaceSummary``，和 iOS 的地图弹卡 / 日历行 / Dashboard
    /// 卡片共用同一份。
    ///
    /// **这里原来是自己写的一份，而且更弱**：只比了 `city` 和 `building`
    /// （Xior 那种两边同名的能挡住），但**没跟房源名比**。于是 OurCampus 那类
    /// 数据照样念两遍——名字 "OurCampus Diemen #3250"、副标题
    /// "OurCampus Amsterdam Diemen"，两串互不包含，整串比较全部放行。
    /// `PlaceSummary` 是**按词**过滤的：OurCampus 和 Diemen 名字里已经有，
    /// 真正新的只有 Amsterdam。
    ///
    /// 返回空串而不是 nil：两个调用点（标题下那行、独立窗口的
    /// `navigationSubtitle`）都要一个 `String`，空串在两处都是"什么都不画"。
    static func subtitle(_ l: Listing) -> String {
        PlaceSummary.text(name: l.name, parts: [l.city, l.buildingText ?? ""]) ?? ""
    }

    /// 设计稿写的是 `€1,067 / mo`。
    ///
    /// 走 ``Listing/priceText`` 拿归一之后的串（`€1125`），不再原样显示
    /// `price_raw`——各平台写法不是一套，OurDomain 的 `"€ 1.125"` 会被读成小数。
    ///
    /// 归一成功的串里不会再带平台自己的「per month」后缀，本可以无条件拼 `/ mo`；
    /// 但归一失败时会**原样回退**，那种串可能自带后缀，所以下面那段判断保留——
    /// 不判断的话会出现 "On request per month / mo"。
    static func price(_ l: Listing) -> String? {
        guard let raw = l.priceText, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        let hasPeriod = lower.contains("mo") || lower.contains("month")
                     || lower.contains("/") || lower.contains("p.m")
        return hasPeriod ? raw : "\(raw) / mo"
    }

    /// `First seen 38m ago · last checked 2m ago`。
    /// 两个都是后端已有的字段（`first_seen` / `last_seen`），不是新东西。
    static func provenance(_ l: Listing) -> String? {
        let parts = [
            l.firstSeen.map { "First seen \(ServerTime.relativeTime($0))" },
            l.lastSeen.map { "last checked \(ServerTime.relativeTime($0))" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - 视图

/// 标题 + `城市 · 楼盘`。
struct ListingHeading: View {

    let listing: Listing
    /// 独立窗口里标题就是窗口的主体，可以大一档；右栏里它上面还有别的东西。
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(listing.name)
                .font(prominent ? .title.weight(.semibold) : .title2.weight(.semibold))
                .tracking(-0.25)
                .textSelection(.enabled)
            Text(ListingText.subtitle(listing))
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// 状态胶囊 + 平台徽章。
struct ListingBadgeRow: View {

    let listing: Listing

    var body: some View {
        HStack(spacing: 7) {
            StatusPill(status: listing.status)
            PlatformBadge(source: listing.source)
            Spacer(minLength: 0)
        }
    }
}

/// 八行「标签 值」。标签左对齐固定宽，值**右对齐**——
/// 右对齐让所有数值贴着同一条线，竖着扫的时候不用逐行找。
struct ListingFactsTable: View {

    let listing: Listing

    var body: some View {
        VStack(spacing: 0) {
            LabeledRow("Price", ListingText.price(listing), mono: true)
            LabeledRow("Area", listing.normalizedAreaText, mono: true)
            LabeledRow("Type", RoomType.display(listing.typeText))
            LabeledRow("Floor", listing.floorText)
            LabeledRow("Energy", listing.energyText,
                       color: EnergyStyle.color(listing.energyText))
            LabeledRow("Contract", listing.contractText)
            LabeledRow("Platform", Platform.displayName(listing.source))
            LabeledRow("Available", listing.availableFrom.map(ServerTime.displayDate))
        }
    }
}

/// 最下面那行灰字。拿不到两个时间戳就整段不画，不显示 "unknown"。
struct ListingProvenance: View {

    let listing: Listing

    var body: some View {
        if let text = ListingText.provenance(listing) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// 一行铺不下就换行。设计稿那句 `flex-wrap: wrap` 的直译。
///
/// 为什么要真的写一个 `Layout`
/// ------------------------
/// 原先是**两个写死的 `HStack`**：第一行放主操作和钉住，第二行放其余。注释写的是
/// "三个按钮会换行"，但那不是换行，是预先分好的两行——按钮数一变就露馅。
/// 加上「分享」之后第二行挤了三个，右栏 300pt 宽装不下，三个一起被截成
/// `Copy Li… / Share… / Open in…`，而那条注释的原意恰恰是**不许截断**。
///
/// 写死分行在两端都不对：右栏宽度是可调的（270–420），420 时本来能少换一行，
/// 270 时两行也不够。真按可用宽度铺，两端都对。
struct WrappingRow: Layout {

    var spacing: CGFloat = 7
    var lineSpacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = layout(subviews, maxWidth: width)
        let height = lines.reduce(0) { $0 + $1.height } +
                     lineSpacing * CGFloat(max(0, lines.count - 1))
        // 宽度返回**实际用到的**最大行宽，不是 proposal：返回 proposal 的话，
        // 这块会把父容器撑满，`Spacer(minLength: 0)` 那种左对齐就失效了。
        let used = lines.map(\.width).max() ?? 0
        return CGSize(width: min(used, width), height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var y = bounds.minY
        for line in layout(subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(_ subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            // 一个都放不下时也要放：宁可让唯一那个溢出，也不能产生一个空行
            // 然后无限循环。
            if needed > maxWidth, !current.indices.isEmpty {
                lines.append(current)
                current = Line()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}

/// 详情里那种矮按钮。
///
/// 设计稿的按钮是 26pt 高、圆角 7——比 AppKit 默认按钮矮一档，和右栏其余元素的
/// 密度对得上。主按钮填 ink（强调色），其余填 6% 灰。
///
/// 和上面几个一样，从 `InspectorPane` 抽出来是因为独立窗口要用同一套——
/// 两处各画一个"差不多的矮按钮"，迟早差出 1pt 和半个圆角。
struct ListingActionButton: View {

    let title: String
    var prominent = false
    /// 撑满可用宽度。
    ///
    /// 光在外面套 `.frame(maxWidth: .infinity)` 不管用：那只会把**按钮**摊开，
    /// 里面的文字和它那层圆角底还是内容宽——菜单栏面板里的 `Open FlatRadar`
    /// 第一版就是这样，一个窄药丸飘在 232pt 的面板正中间。要撑开的是底，
    /// 所以这个 flag 得加在 `.background` **之前**。
    var fullWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(prominent ? .medium : .regular))
                .foregroundStyle(prominent ? AnyShapeStyle(Color(nsColor: .textBackgroundColor))
                                           : AnyShapeStyle(Color.primary))
                .padding(.horizontal, 11)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: 26)
                .background(prominent ? AnyShapeStyle(Theme.ink)
                                      : AnyShapeStyle(Color.primary.opacity(0.06)),
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}
