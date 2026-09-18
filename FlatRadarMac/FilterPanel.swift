import SwiftUI
import FlatRadarCore

/// 「All filters」展开的那一块。
///
/// 照设计稿 t3 的四列排：Location / Price & size / Property / Status & timing，
/// 底下一排平台 chip。每个选项后面跟一个**全局**计数（为什么是全局而不是交叉，
/// 见 ``ListingQuery/options(_:value:label:)``）。
///
/// 候选项全部**从当前这批房源里现取**，不是写死的表也不是 `/filter/options`：
/// - 写死的表会列出这批数据里一条都没有的城市，勾了得到空列表；
/// - `/filter/options` 是**通知筛选器**的候选集，口径和"我现在看的这 822 条"
///   不是一回事（实测库里 828 条、账号筛出来 80 条）。
///
/// 这一屏的筛选是**本地**的，和 `/me/filter` 那个跟账号走的通知筛选器没有关系——
/// 两者混在一起正是侧栏那段 Saved Filters 被删掉的原因。
struct FilterPanel: View {

    @Bindable var model: BrowseModel

    private var all: [Listing] { model.listings.listings }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 20) {
                column("Location") { cities }
                column("Price & size") { priceAndSize }
                column("Property") { property }
                column("Status & timing") { statusAndTiming }
            }
            platforms
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 四列

    private func column<C: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cities: some View {
        scrollingOptions(ListingQuery.options(all, value: \.city),
                         keyPath: \.cities)
    }

    private var priceAndSize: some View {
        VStack(alignment: .leading, spacing: 7) {
            numberField("Max rent", unit: "€", text: maxRent)
            numberField("Min area", unit: "m²", text: minArea)
            // 读不出价格 ≠ 超预算。说清楚，免得用户以为漏了。和地图那个浮层同一句话。
            Text("Listings whose rent or area cannot be read are kept rather than hidden.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var property: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 显示走 `RoomType.display`，和表格 Type 那一列同一套：后端的房型有
            // `Studio` / `Loft` 这样的词，也有 `1` / `2` 这样光秃秃的数字。
            // **筛选用的值仍然是原串**，只有标签变——两者错开的话勾了会筛不到。
            scrollingOptions(ListingQuery.options(all, value: { $0.typeText },
                                                  label: { RoomType.display($0) ?? $0 }),
                             keyPath: \.types, maxHeight: 74)
            let energy = ListingQuery.options(all, value: { $0.energyText })
            if !energy.isEmpty {
                Text("Energy")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                // B 及以下 `EnergyStyle.color` 返回 nil（由调用方落到正文色），
                // chip 上那个点就用次要色，别硬凑一个绿。
                chipRow(energy, keyPath: \.energy, perRow: 2) { EnergyStyle.color($0) ?? .secondary }
            }
        }
    }

    private var statusAndTiming: some View {
        VStack(alignment: .leading, spacing: 4) {
            let counts = ListingQuery.statusCounts(all)
            // 状态按 `ListingStatus` 的声明顺序，不按条数——那几档的先后有含义。
            ForEach(ListingStatus.allCases) { status in
                if let n = counts[status], n > 0 {
                    Toggle(isOn: setBinding(\.statuses, status)) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.statusColor(status))
                                .frame(width: 7, height: 7)
                            Text(Theme.shortStatusLabel(status) ?? status.label)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            count(n)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.body)
                }
            }
            Toggle(isOn: $model.query.datedOnly) {
                Text("Has a move-in date").font(.body)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 3)
        }
    }

    // MARK: - 平台

    /// 平台单独一排 chip，不并进四列里。
    ///
    /// 它是**跨列**的维度：城市、价格、房型都是房子的属性，平台是"这条数据从哪儿
    /// 来的"。设计稿也是这么排的。
    private var platforms: some View {
        let options = ListingQuery.options(all, value: { $0.source },
                                           label: { Platform.shortName($0) })
        return Group {
            if !options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Platforms")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    chipRow(options, keyPath: \.sources) { Theme.platform($0) }
                }
            }
        }
    }

    // MARK: - 零件

    private func scrollingOptions(_ options: [FilterOption],
                                  keyPath: WritableKeyPath<ListingQuery, Set<String>>,
                                  maxHeight: CGFloat = 104) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(options) { option in
                    Toggle(isOn: setBinding(keyPath, option.value)) {
                        HStack(spacing: 6) {
                            Text(option.label).lineLimit(1)
                            Spacer(minLength: 8)
                            count(option.count)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: maxHeight)
        // 候选项可能就两三条，别让滚动区撑出一片空白。
        .fixedSize(horizontal: false, vertical: options.count <= 3)
    }

    /// 一排 chip。`perRow` 给的是每行放几个——列宽不够时 `HStack` 不会换行，
    /// 只会把 chip 压扁，`A++` 会在 chip 里折成两行（实测就是这样）。
    /// `Layout` 对这点事太重，按固定个数切行就够。
    private func chipRow(_ options: [FilterOption],
                         keyPath: WritableKeyPath<ListingQuery, Set<String>>,
                         perRow: Int = .max,
                         color: @escaping (String) -> Color) -> some View {
        let rows = perRow == .max ? [Array(options)]
            : stride(from: 0, to: options.count, by: perRow).map {
                Array(options[$0..<min($0 + perRow, options.count)])
            }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row) { option in chip(option, keyPath: keyPath, color: color) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chip(_ option: FilterOption,
                      keyPath: WritableKeyPath<ListingQuery, Set<String>>,
                      color: (String) -> Color) -> some View {
        let on = model.query[keyPath: keyPath].contains(option.value)
        return Button {
            if on { model.query[keyPath: keyPath].remove(option.value) }
            else { model.query[keyPath: keyPath].insert(option.value) }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(color(option.value)).frame(width: 6, height: 6)
                Text(option.label).font(.caption.weight(.medium))
                count(option.count)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(on ? Theme.selectionFill : Color.primary.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }

    private func count(_ n: Int) -> some View {
        Text("\(n)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
    }

    private func numberField(_ label: LocalizedStringKey, unit: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.body).frame(width: 62, alignment: .leading)
            TextField("Any", text: text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 66)
            Text(unit).font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: - 绑定

    private func setBinding<T: Hashable>(_ keyPath: WritableKeyPath<ListingQuery, Set<T>>,
                                         _ value: T) -> Binding<Bool> {
        Binding(
            get: { model.query[keyPath: keyPath].contains(value) },
            set: { on in
                if on { model.query[keyPath: keyPath].insert(value) }
                else { model.query[keyPath: keyPath].remove(value) }
            })
    }

    /// 输入框存的是**文本**、条件存的是数——空串对应"不限"（`nil`），
    /// 不是 0。0 会把所有房源都筛掉，而用户清空输入框的意思是"别筛了"。
    private var maxRent: Binding<String> {
        Binding(get: { model.query.maxRent.map { String(Int($0)) } ?? "" },
                set: { model.query.maxRent = Double($0.filter(\.isNumber)) })
    }

    private var minArea: Binding<String> {
        Binding(get: { model.query.minArea.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "" },
                set: { model.query.minArea = Double($0.replacingOccurrences(of: ",", with: ".")) })
    }
}
