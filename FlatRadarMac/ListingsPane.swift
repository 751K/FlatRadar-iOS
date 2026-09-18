import SwiftUI
import AppKit
import FlatRadarCore

/// 列表屏：统计带 + 筛选条 + 表格 + 状态栏。
///
/// 从原来的 `BrowseWindow` 拆出来的。拆的理由见 ``MainWindow``：地图和日历要
/// 共用右侧同一个 inspector，那就不能让每一屏各自带一个 `NavigationSplitView`。
struct ListingsPane: View {

    /// 键盘焦点落在哪儿。
    ///
    /// 必须是**一个** `@FocusState` 上的枚举，不能是两个各自独立的 Bool：
    /// 两个 Bool 可以同时为 true，那时候 ↑↓ 到底谁接就没定义了。
    enum Focus: Hashable { case table, search }

    @Bindable var model: BrowseModel
    let summary: SummaryModel

    @FocusState private var focus: Focus?

    /// 首屏自动聚焦只做一次。
    ///
    /// docs/MACOS.md Phase 2 的完成判据里有一条「筛选和刷新不抢走键盘焦点」——
    /// 每次数据变化都抢一次焦点的话，你正在搜索框里打字，一个后台刷新回来就把
    /// 光标抢走了。这个 flag 就是那条判据。
    @State private var didFocusTable = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            statusBar
        }
        .onChange(of: model.searchFocusRequests) { _, _ in focus = .search }
        // 数据到齐 → 选中第一条 → 把焦点交给表格，这样一启动就能直接按 ↑↓。
        .onChange(of: model.listings.listings.count) { _, count in
            guard !didFocusTable, count > 0 else { return }
            didFocusTable = true
            model.selectFirstRowIfNeeded()
            focus = .table
        }
        // 搜索把当前选中那条筛掉了的话，焦点落到第一条可见行，而不是留一个
        // 看不见的选中项——那会让 ↑↓ 从一个屏幕上不存在的位置开始走。
        .onChange(of: model.searchText) { _, _ in
            model.reconcileSelection()
        }
    }

    // MARK: - 顶部：统计带 + 筛选条

    private var header: some View {
        VStack(spacing: 10) {
            if !summary.failed {
                StatsStrip(summary: summary, listings: model.listings)
            }
            filterBar
            if model.showFilterPanel {
                FilterPanel(model: model)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }


    /// 筛选条：搜索框 + 一排**带值的 token** + All filters + Clear。
    ///
    /// 设计稿 t3 把筛选做成两层：收起时每个生效的条件是一个写着**当前值**的 token
    /// （`Eindhoven, Rotterdam` / `€400 – €1,200`），而不是一排永远长一样的下拉框。
    /// 差别在于扫一眼就知道"现在筛的是什么"，不用逐个点开确认。
    ///
    /// token 一个维度一条，见 ``BrowseModel/activeFilterTokens``。
    private var filterBar: some View {
        HStack(spacing: 7) {
            searchField
            ForEach(model.activeFilterTokens) { token in
                filterToken(token)
            }
            Spacer(minLength: 8)
            allFiltersToken
            if model.hasActiveFilters {
                Button("Clear") { model.clearFilters() }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 25)
    }

    private func filterToken(_ token: FilterToken) -> some View {
        Button {
            token.remove()
        } label: {
            HStack(spacing: 6) {
                Text(token.label)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    // 装饰性 glyph：和 label 一起被读会变成 "Eindhoven xmark"。
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove filter: \(token.label)")
    }

    private var allFiltersToken: some View {
        Button {
            model.showFilterPanel.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("All filters")
                    .font(.body)
                Image(systemName: model.showFilterPanel ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search address or building", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focus, equals: .search)
                // 边打字筛选边用 ↑↓ 翻结果，手不离开键盘。焦点留在搜索框里，
                // 所以还能接着改关键词——Spotlight / Alfred 的手感。
                .onKeyPress(.upArrow) { model.moveSelection(by: -1); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(by: 1); return .handled }
                // Esc：先清关键词，已经空了就把焦点还给表格。
                // 两段式是因为「清空」和「离开」是两个不同的意图，
                // 一个 Esc 同时干两件事的话，想清空的人会连焦点一起丢掉。
                .onKeyPress(.escape) {
                    if model.searchText.isEmpty {
                        focus = .table
                    } else {
                        model.searchText = ""
                    }
                    return .handled
                }
                .onSubmit { focus = .table }
        }
        .padding(.horizontal, 9)
        .frame(width: 210, height: 25)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - 中间：表格与各种空状态

    @ViewBuilder
    private var content: some View {
        if model.listings.isLoading && model.listings.listings.isEmpty {
            centered { ProgressView("Loading listings…") }
        } else if let err = model.listings.errorMessage, model.listings.listings.isEmpty {
            centered { loadFailure(err) }
        } else if model.rows.isEmpty {
            centered { noMatches }
        } else {
            table
        }
    }

    /// 完成判据：空列表 / 加载失败要有明确状态**和重试入口**。
    private func loadFailure(_ message: String) -> some View {
        ContentUnavailableView {
            Label(model.listings.lastError?.errorDescription ?? String(localized: "Unable to Load"),
                  systemImage: model.listings.lastError?.systemImage ?? "wifi.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { Task { await model.reload() } }
        }
    }

    private var noMatches: some View {
        ContentUnavailableView(
            model.searchText.isEmpty ? "No Listings" : "No Matches",
            systemImage: model.searchText.isEmpty ? "house" : "magnifyingglass",
            description: Text(model.searchText.isEmpty
                              ? "Nothing matches the current filter."
                              : "No listing matches “\(model.searchText)”."))
    }

    private var table: some View {
        ListingTable(model: model, isFocused: focus == .table)
            .focusable()
            .focused($focus, equals: .table)
            // 关掉系统焦点环：`.focusable()` 会给整块表格套一圈蓝框，
            // 而"当前在哪一行"已经由行自己的填充说清了，外面再套一圈只是噪音，
            // 也和设计稿「去线」的规则冲突。
            .focusEffectDisabled()
            // 键盘浏览。`List` 不像 `Table` 自带方向键，所以这里全部自己接——
            // 换来的是行的完全控制权（悬停、选中色、无分隔线），见 ``ListingTable``。
            .onKeyPress(phases: .down) { press in
                switch press.key {
                case .upArrow:
                    model.moveSelection(by: -1,
                                        extending: press.modifiers.contains(.shift))
                    return .handled
                case .downArrow:
                    model.moveSelection(by: 1,
                                        extending: press.modifiers.contains(.shift))
                    return .handled
                case .return:
                    if let l = model.listing(model.focused) { openOriginal(l) }
                    return .handled
                default:
                    return .ignored
                }
            }
            .onChange(of: model.sortOrder) { _, _ in
                Task { await model.applySortOrder() }
            }
    }

    // MARK: - 底部状态栏

    private var statusBar: some View {
        HStack(spacing: 10) {
            // 窗口底栏是 chrome，不是数据：走 `.subheadline`（见 ``Theme`` 的字阶注释）。
            // Finder 底栏也是这个量级。
            Text(rangeText)
                .font(.subheadline)
                .foregroundStyle(model.listings.loadMoreFailed ? .orange : .secondary)
            if model.listings.loadMoreFailed {
                Button("Retry") { Task { await model.reload() } }
                    .buttonStyle(.link)
            }
            Spacer()
            if !model.pinned.isEmpty {
                Text("\(model.pinned.count) pinned")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if model.listings.isLoading || model.listings.isLoadingMore {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    /// 完成判据里的「排序范围准确可见」。全量拉完时说清是全部；没拉完时
    /// **必须**说明排序只覆盖已加载的部分，否则用户会以为看到的是全局最低价。
    private var rangeText: String {
        let store = model.listings
        if store.loadMoreFailed {
            return String(localized: "Loaded \(store.listings.count) of \(store.total) — paging failed, sorting covers only what loaded")
        }
        // 判据是 `hasActiveFilters` 而不是"搜索框空不空"。
        //
        // 原来写的是 `model.searchText.isEmpty`——那时候搜索框**是**唯一的筛选条件，
        // 两者等价。`FilterPanel` 进来之后就不等价了：勾了城市但没打字时，这一行
        // 会继续说「84 listings」，而表里只有 37 条。状态栏报的数和眼前的表对不上，
        // 是这一行最不该犯的错。
        let shown = model.rows.count
        if !model.hasActiveFilters {
            return String(localized: "\(store.total) listings, sorted by \(sortLabel)")
        }
        return String(localized: "\(shown) of \(store.total) match, sorted by \(sortLabel)")
    }

    private var sortLabel: String {
        guard let c = model.sortOrder.first else { return String(localized: "default order") }
        let key: String = switch c.key {
        case .price: String(localized: "Price")
        case .area: String(localized: "Area")
        case .energy: String(localized: "Energy")
        case .firstSeen: String(localized: "First seen")
        case .lastSeen: String(localized: "Last seen")
        case .availableFrom: String(localized: "Available")
        case .city: String(localized: "City")
        case .status: String(localized: "Status")
        case .source: String(localized: "Platform")
        }
        let direction = c.order == .forward ? "↑" : "↓"
        return String(localized: "\(key) \(direction)")
    }

    private func openOriginal(_ l: Listing) {
        guard let url = URL(string: l.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
