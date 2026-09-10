import SwiftUI
import FlatRadarCore

/// 房源表格：自绘列头 + 自绘行的 `List`。
///
/// 为什么不是 SwiftUI 的 `Table`
/// ---------------------------
/// 先用的 `Table`，撞上三件设计稿要求而它做不到的事，**根因是同一个**：
/// `Table` 只给你一格一格的内容闭包，没有「行」这一层可以挂修饰符。
///
/// | 要求 | `Table` 上的结果 |
/// |---|---|
/// | 悬停整行浮起 | `.onHover` **完全不触发**（用不透明红色探过，毫无反应）—— NSTableView 自己吃掉了鼠标跟踪 |
/// | 选中行改中性灰 | `.tint()` 对选中高亮无效，只能用系统色 |
/// | 去掉行分隔线 | 没有修饰符；AppKit 的 `NSTableView.appearance()` 是 UIKit API，macOS 上不存在 |
///
/// 换成 `List` 之后三件一起解决，代价是列头要自己写。
/// **这个代价比看上去小**：设计稿的表格本来就是固定列宽的九列网格
/// （`grid-template-columns: 298px 80px 84px …`），原生的拖拽改列宽根本不在设计里。
/// 真正手写的只有「点列头换排序 + ▲▼ 箭头」，以及多选（⌘ 点选 / ⇧ 连选）。
struct ListingTable: View {

    @Bindable var model: BrowseModel
    /// 表格要不要接键盘。由外层的 `@FocusState` 给。
    var isFocused: Bool

    @State private var hoveredID: Listing.ID?

    var body: some View {
        VStack(spacing: 0) {
            ListingTableHeader(model: model)
            rows
        }
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.rows) { listing in
                    ListingTableRow(listing: listing,
                                    isSelected: model.selection.contains(listing.id),
                                    isHovered: hoveredID == listing.id,
                                    isPinned: model.pinned.contains(listing.id))
                        .id(listing.id)
                        .onHover { inside in
                            if inside {
                                hoveredID = listing.id
                            } else if hoveredID == listing.id {
                                hoveredID = nil
                            }
                        }
                        .onTapGesture { click(listing) }
                        .contextMenu { rowMenu(listing) }
                        // 行自己画背景和圆角，所以 List 那套默认 chrome 全关掉。
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // 键盘移动之后要把新焦点滚进视野，否则按住 ↓ 会"翻到看不见的地方"。
            .onChange(of: model.focused) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    // MARK: - 点选

    /// 单击 / ⌘ 点选 / ⇧ 连选。
    ///
    /// `Table` 白送的这三件事现在要自己写。语义按 Finder 来：
    /// - 单击：只选这一条
    /// - ⌘ 点：加进 / 移出选择集，焦点跟到点的那条
    /// - ⇧ 点：从当前焦点到点的那条整段选上
    private func click(_ listing: Listing) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if model.selection.contains(listing.id) {
                model.selection.remove(listing.id)
            } else {
                model.selection.insert(listing.id)
            }
            model.focused = listing.id
        } else if mods.contains(.shift), let anchor = model.focused {
            model.selectRange(from: anchor, to: listing.id)
        } else {
            model.selection = [listing.id]
            model.focused = listing.id
        }
    }

    @ViewBuilder
    private func rowMenu(_ l: Listing) -> some View {
        Button(model.pinned.contains(l.id) ? "Unpin" : "Pin for Comparison") {
            model.togglePin(l.id)
        }
        Divider()
        Button("Open on \(Platform.displayName(l.source))") {
            if let url = URL(string: l.url) { NSWorkspace.shared.open(url) }
        }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(l.url, forType: .string)
        }
    }
}

// MARK: - 列定义

/// 九列的宽度、对齐和排序键。**列头和行共用这一份**，所以两者永远对得齐——
/// 自绘表格最容易出的错就是列头和行各写一套宽度，改一处忘一处。
enum ListingColumn: String, CaseIterable, Identifiable {
    case address, city, price, area, type, energy, platform, status, available

    var id: String { rawValue }

    var title: String {
        switch self {
        case .address:   return "Address"
        case .city:      return "City"
        case .price:     return "Price"
        case .area:      return "Area"
        case .type:      return "Type"
        case .energy:    return "Energy"
        case .platform:  return "Plat."
        case .status:    return "Status"
        case .available: return "Available"
        }
    }

    /// 设计稿的固定宽度。Address 返回 nil = 吃掉剩余宽度。
    ///
    /// 设计稿给 Address 写死 298，这里改成弹性：窗口是连续可变的，写死会在宽屏上
    /// 留一条空带、在窄屏上先截地址。其余八列照抄设计稿，只有 Area 从 58 加到 68
    /// ——设计稿那个数是按 "28 m²" 量的，真实数据里有 "87.28 m²"，58 装不下。
    var width: CGFloat? {
        switch self {
        case .address:   return nil
        case .city:      return 80
        case .price:     return 84
        case .area:      return 68
        case .type:      return 94
        case .energy:    return 52
        case .platform:  return 56
        case .status:    return 96
        case .available: return 82
        }
    }

    /// 数字右对齐：贴同一条线才好竖着比。
    var alignment: Alignment {
        switch self {
        case .price, .area: return .trailing
        default:            return .leading
        }
    }

    /// 服务端能排的键。`nil` = 这一列点了没反应（后端 1.23.0 的 sort enum 里
    /// 没有 `name` 和房型），**所以列头也不画箭头**——不给能点的暗示。
    var sortKey: ListingSortKey? {
        switch self {
        case .city:      return .city
        case .price:     return .price
        case .area:      return .area
        case .energy:    return .energy
        case .platform:  return .source
        case .status:    return .status
        case .available: return .availableFrom
        case .address, .type: return nil
        }
    }

    /// 第一次点这一列时用哪个方向。
    ///
    /// 「最便宜的」「最小的」「最快能住的」都是升序，而日期类想先看最新的。
    var defaultAscending: Bool { self != .available }
}

// MARK: - 列头

private struct ListingTableHeader: View {

    @Bindable var model: BrowseModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ListingColumn.allCases) { column in
                headerCell(column)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    @ViewBuilder
    private func headerCell(_ column: ListingColumn) -> some View {
        let active = model.sortOrder.first.flatMap { c in
            column.sortKey == c.key ? c : nil
        }
        Button {
            toggleSort(column)
        } label: {
            HStack(spacing: 4) {
                if column.alignment == .trailing { Spacer(minLength: 0) }
                Text(column.title)
                    .font(.subheadline.weight(active != nil ? .semibold : .regular))
                    .foregroundStyle(active != nil ? AnyShapeStyle(.secondary)
                                                   : AnyShapeStyle(.tertiary))
                if let active {
                    Image(systemName: active.order == .forward ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                if column.alignment == .leading { Spacer(minLength: 0) }
            }
            .padding(.trailing, column.alignment == .trailing ? 12 : 0)
            .frame(width: column.width, alignment: column.alignment)
            .frame(maxWidth: column.width == nil ? .infinity : nil,
                   alignment: column.alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(column.sortKey == nil)
    }

    /// 点已经在排的那一列 → 翻方向；点别的列 → 换成那一列的默认方向。
    private func toggleSort(_ column: ListingColumn) {
        guard let key = column.sortKey else { return }
        if let current = model.sortOrder.first, current.key == key {
            model.sortOrder = [ListingColumnComparator(
                key: key, order: current.order == .forward ? .reverse : .forward)]
        } else {
            model.sortOrder = [ListingColumnComparator(
                key: key, order: column.defaultAscending ? .forward : .reverse)]
        }
    }
}

// MARK: - 行

private struct ListingTableRow: View {

    let listing: Listing
    let isSelected: Bool
    let isHovered: Bool
    let isPinned: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ListingColumn.allCases) { column in
                cell(column)
                    .padding(.trailing, column.alignment == .trailing ? 12 : 0)
                    .frame(width: column.width, alignment: column.alignment)
                    .frame(maxWidth: column.width == nil ? .infinity : nil,
                           alignment: column.alignment)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 45)
        .modifier(RowSurface(isSelected: isSelected, isHovered: isHovered))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 整行合并成一个读屏元素，拼一句完整的话。
    /// 默认逐格朗读会把「€1800」「87.28 m²」「Occupied」念成三个孤立的碎片。
    private var a11yLabel: String {
        var parts: [String] = [listing.name]
        if !listing.city.isEmpty { parts.append(listing.city) }
        if let p = listing.priceRaw { parts.append(p) }
        if let a = listing.normalizedAreaText { parts.append(a) }
        let kind = ListingStatus.from(listing.status)
        parts.append(Theme.shortStatusLabel(kind) ?? listing.status)
        if let avail = listing.availableFrom.map(ServerTime.displayDate) {
            parts.append("from \(avail)")
        }
        if isPinned { parts.append("pinned") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func cell(_ column: ListingColumn) -> some View {
        switch column {
        case .address:
            HStack(spacing: 8) {
                // 钉住标记：6pt 墨色菱形。设计稿把它放在**行内**而不是只在侧栏，
                // 这样扫表格时一眼能看出哪两条是自己钉的。
                Rectangle()
                    .fill(isPinned ? Theme.ink : .clear)
                    .frame(width: 6, height: 6)
                    .rotationEffect(.degrees(45))
                VStack(alignment: .leading, spacing: 2) {
                    Text(listing.name)
                        .font(.body)
                        .tracking(-0.1)
                        .lineLimit(1)
                    if let b = listing.buildingText, !b.isEmpty {
                        Text(b)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        case .city:
            Text(listing.city)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .price:
            Text(listing.priceRaw ?? "—")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .monospacedDigit()
        case .area:
            Text(listing.normalizedAreaText ?? "—")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .type:
            Text(RoomType.display(listing.typeText) ?? "—")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .energy:
            EnergyLabel(text: listing.energyText)
        case .platform:
            PlatformBadge(source: listing.source)
        case .status:
            StatusPill(status: listing.status)
        case .available:
            let text = listing.availableFrom.map(ServerTime.displayDate)
            Text(text ?? "—")
                .font(.callout)
                // 缺失的日期更淡一档，扫视时就能和"有值"分开。
                .foregroundStyle(text == nil ? AnyShapeStyle(.tertiary)
                                             : AnyShapeStyle(.secondary))
                .monospacedDigit()
        }
    }
}
