import SwiftUI
import FlatRadarCore

/// Listings 视图 —— BrowseView 内嵌的"列表"模式。
///
/// 不再持有 NavigationStack；外层 BrowseView 提供 NavigationStack(path:) +
/// navigationDestination，本视图只贡献内容 + 自己的 toolbar item。
struct ListingsView: View {
    @Environment(ListingsStore.self) private var store
    @Environment(NavigationCoordinator.self) private var coord
    /// 分区标题的绿色要按明暗两套压暗/提亮，见 ``Color/onTint(in:)``。
    @Environment(\.colorScheme) private var scheme
    @State private var searchText = ""
    @State private var searchDraft = ""
    @State private var showSearch = false
    @State private var showFilters = false
    @State private var showRefreshError = false
    /// Filter Apply 触觉反馈 trigger —— 每按一次 Apply 自增，驱动 `.sensoryFeedback`
    @State private var filterApplyTick = 0
    @State private var selectedStatus = ""
    @State private var sort = ListingSortOption.newest
    @State private var selectedSources: [String] = []
    @State private var selectedCities: [String] = []
    @State private var selectedTypes: [String] = []
    @State private var selectedContract = ""
    @State private var selectedEnergy = ""

    // 缓存排序 + 分桶结果，避免每次 body 重算 O(n log n) + O(n) date parse
    @State private var cachedSorted: [Listing] = []
    @State private var cachedNew: [Listing] = []
    @State private var cachedEarlier: [Listing] = []
    @State private var sortVersion = 0

    /// `body` 原本是「Group { 三分支 } + 9 个 modifier」一整个表达式。
    /// Core 拆成独立模块后跨模块推断变贵，整条链的类型检查会超时。
    /// 把内容和 modifier 链切成两段，各自独立求解；渲染结果不变。
    @ViewBuilder
    private var content: some View {
            Group {
                if store.isLoading && store.listings.isEmpty {
                    ProgressView().padding(.top, 60)
                } else if let err = store.errorMessage, store.listings.isEmpty {
                    let apiErr = store.lastError
                    let title: String = apiErr?.errorDescription ?? "Unable to Load"
                    let icon: String = apiErr?.systemImage ?? "wifi.slash"
                    ContentUnavailableView {
                        Label(title, systemImage: icon)
                    } description: {
                        Text(err)
                    } actions: {
                        Button("Try Again") {
                            Task { await store.refresh() }
                        }
                    }
                } else if store.listings.isEmpty {
                    ContentUnavailableView(
                        "No Listings",
                        systemImage: "house",
                        description: Text(store.isFiltered
                            ? "No listings match your filter."
                            : "No listings found."))
                    .refreshable { await store.refresh() }
                } else {
                    listContent
                }
            }
    }

    var body: some View {
        content
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    searchDraft = searchText
                    withAnimation(.spring(duration: 0.28, bounce: 0.12)) {
                        showSearch.toggle()
                    }
                } label: {
                    Label(searchButtonTitle, systemImage: searchText.isEmpty
                        ? "magnifyingglass"
                        : "magnifyingglass.circle.fill")
                }
                .tint(searchText.isEmpty ? nil : .blue)

                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(ListingSortOption.allCases) { option in
                            Label(option.title, systemImage: option.systemImage)
                                .tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }

                Button {
                    showFilters = true
                } label: {
                    Label(filterButtonTitle, systemImage: activeFilterCount > 0
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                }
                .tint(activeFilterCount > 0 ? .blue : nil)
            }
        }
        .sheet(isPresented: $showFilters) {
            ListingFilterSheet(
                selectedStatus: $selectedStatus,
                selectedSources: $selectedSources,
                selectedCities: $selectedCities,
                selectedTypes: $selectedTypes,
                selectedContract: $selectedContract,
                selectedEnergy: $selectedEnergy,
                activeFilterCount: activeFilterCount,
                apply: {
                    filterApplyTick &+= 1   // 触发 .sensoryFeedback(.selection, …)
                    showFilters = false
                    Task { await fetchWithCurrentFilters() }
                },
                reset: {
                    selectedStatus = ""
                    selectedSources = []
                    selectedCities = []
                    selectedTypes = []
                    selectedContract = ""
                    selectedEnergy = ""
                    showFilters = false
                    Task { await fetchWithCurrentFilters() }
                })
        }
        .task {
            if store.listings.isEmpty {
                await store.fetch()
            }
            recomputeCachedListings()
        }
        .onChange(of: store.errorMessage) { _, new in
            showRefreshError = new != nil && !store.listings.isEmpty
        }
        .onChange(of: store.listings) { _, _ in recomputeCachedListings() }
        // 换排序要**重新向服务端要**，不能只把已加载的重排——后者排出来的是
        // 「已加载结果里最便宜的」，不是「全部里最便宜的」。见 ListingSort。
        .onChange(of: sort) { _, newValue in
            guard let server = newValue.serverSort else {
                // `.name` 暂时没有服务端对应，退回本地排（只排已加载的）。
                recomputeCachedListings()
                return
            }
            Task { await store.setSort(server) }
        }
        .alert(
            refreshErrorTitle,
            isPresented: $showRefreshError
        ) {
            Button("OK") {}
        } message: {
            Text(refreshErrorMessage)
        }
        // Filter Apply 轻触反馈 —— 用 .selection 比 .success 更合适：
        // 应用过滤器是 UI 选择确认动作，不是成功完成型操作。
        .sensoryFeedback(.selection, trigger: filterApplyTick)
    }

    /// `.alert` 有一大堆重载，标题位置放 `String?  ?? String` 会让求解器把
    /// 每个重载都试一遍；Core 拆成独立模块后这条链就此超时。先定死类型再传进去。
    private var refreshErrorTitle: String {
        store.lastError?.errorDescription ?? "Refresh Failed"
    }

    private var refreshErrorMessage: String {
        store.errorMessage ?? ""
    }

    private var listContent: some View {
        let sorted = cachedSorted
        let new = cachedNew
        let earlier = cachedEarlier

        return List {
            // —— Live 心跳条 + 活跃 filter chips
            Section {
                if showSearch { inlineSearchRow }
                heartbeatRow
                if !activeFilterChips.isEmpty { filterChipsRow }
            }
            .listRowSeparator(.hidden)

            let lastID = sorted.last?.id

            // —— NEW TODAY · N
            if !new.isEmpty {
                Section {
                    ForEach(new) { listing in
                        row(for: listing, lastID: lastID)
                    }
                } header: {
                    // 原来这里写死 `Color(red: 52/255, green: 199/255, blue: 89/255)`
                    // ——那正好是 systemGreen 的**浅色值** `#34C759`，深色模式下
                    // 系统本该给 `#30D158`，写死之后它停在浅色那一档不动。
                    // 同一个 `sectionHeader` 另外两个调用点传的都是语义样式。
                    //
                    // 不是简单换成 `.green`：这行是 11pt 的分区标题，绿字在白底上
                    // 只有 2.2:1。跟徽标同一条路——压暗一档再用（``Color/onTint(in:)``）。
                    sectionHeader("NEW TODAY · \(new.count)",
                                  color: Color.statusBook.onTint(in: scheme))
                }
            }

            // —— EARLIER
            if !earlier.isEmpty {
                Section {
                    ForEach(earlier) { listing in
                        row(for: listing, lastID: lastID)
                    }
                } header: {
                    // 分支写，不用三元：三元里的两个字面量会被合并成 String，
                    // Text 就走非本地化重载，这两句会从 xcstrings 里消失。
                    if new.isEmpty {
                        sectionHeader("ALL LISTINGS", color: .secondary)
                    } else {
                        sectionHeader("EARLIER", color: .secondary)
                    }
                }
            }

            if store.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
            }
        }
        // .insetGrouped（默认）：灰底 + 白色 inset section 卡片，跟
        // Settings / Notifications / Dashboard 风格一致。
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }

    @ViewBuilder
    private func row(for listing: Listing, lastID: String?) -> some View {
        Button {
            coord.listingsPath.append(ListingRoute.known(listing))
        } label: {
            HStack(spacing: 0) {
                ListingRow(listing: listing)
                Spacer(minLength: 10)
                Image(systemName: "chevron.right")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .onAppear {
            if listing.id == lastID {
                Task { await store.loadMore() }
            }
        }
    }

    @ViewBuilder
    /// 分区标题。
    ///
    /// 参数是 `LocalizedStringKey` 而不是 `String`：后者会让 ``Text`` 走非本地化
    /// 重载，标题就此从 `Localizable.xcstrings` 里消失。2026-09-04 的截图上看得
    /// 很清楚——五种语言的列表页，分区标题全是英文的 ALL LISTINGS / EARLIER，
    /// 而周围的内容都翻译好了。
    private func sectionHeader(_ title: LocalizedStringKey, color: Color) -> some View {
        Text(title)
            .font(.system(.caption2, design: .monospaced, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(color)
            .textCase(nil)
            .padding(.top, 4)
    }

    // MARK: - Heartbeat + chips

    @ViewBuilder
    private var heartbeatRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            (Text("\(store.total)").font(.system(.caption, design: .monospaced, weight: .bold))
                + Text(" listings").font(.system(.caption)))
                .foregroundStyle(.primary)
            Text("·")
                .font(.system(.caption))
                .foregroundStyle(.secondary)
            Text("updated \(updatedAgoText)")
                .font(.system(.caption))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 2)
        // VoiceOver：默认把绿圈 / 数字 / " listings" / · / "updated 8m" 拆成五个
        // 元素读出，节奏碎。combine 后变一个元素，自定义 label 自然朗读。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(store.total) listings, updated \(updatedAgoText)")
    }

    private var inlineSearchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search by name or address", text: $searchDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    applySearch()
                }
            if !searchDraft.isEmpty {
                Button {
                    searchDraft = ""
                    if !searchText.isEmpty {
                        searchText = ""
                        Task { await fetchWithCurrentFilters() }
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            Button("Search") {
                applySearch()
            }
            .font(.subheadline.weight(.semibold))
            .disabled(searchDraft.trimmingCharacters(in: .whitespacesAndNewlines) == searchText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(activeFilterChips) { chip in
                    Button {
                        chip.remove()
                    } label: {
                        HStack(spacing: 5) {
                            Text(chip.label)
                                .font(.system(.caption, design: chip.mono ? .monospaced : .default,
                                              weight: .semibold))
                            Image(systemName: "xmark")
                                .font(.system(.caption2, weight: .bold))
                                // 装饰性 glyph：跟 chip label 一起被读会变成
                                // "Eindhoven xmark"——把它从 a11y 树里摘掉，
                                // 让按钮整体只暴露一个清晰意图。
                                .accessibilityHidden(true)
                        }
                        .padding(.leading, 11)
                        .padding(.trailing, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(chip.active ? Color.accentColor : Color(.secondarySystemBackground))
                        )
                        .foregroundStyle(chip.active ? Color.white : Color.primary)
                        .overlay(
                            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: chip.active ? 0 : 0.5)
                        )
                        // 视觉 chip 高约 22pt（保留紧凑设计），用 minHeight + contentShape
                        // 把按钮的命中区上下补到 44pt 满足 HIG，不让 chip 视觉变高。
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                        .shadow(color: chip.active ? Color.accentColor.opacity(0.25) : .clear,
                                radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    // VoiceOver 朗读："Remove filter: Eindhoven, button"；
                    // Voice Control 也能用"tap Remove filter Eindhoven"。
                    .accessibilityLabel("Remove filter: \(chip.label)")
                }
                if activeFilterChips.count > 1 {
                    Button("Clear All", role: .destructive) {
                        clearAllFilters()
                    }
                    .font(.system(.caption, weight: .semibold))
                    .padding(.leading, 4)
                }
            }
        }
    }

    // MARK: - Derived data

    /// 当 listings 或排序变化时重新计算缓存，避免 body 重渲染时反复 O(n log n)。
    private func recomputeCachedListings() {
        // 有服务端排序时 `store.listings` 已经是排好的，原样用；
        // 只有 `.name`（后端 enum 里还没有）才在本地排。
        let sorted = sort.serverSort == nil
            ? store.listings.sorted(using: sort)
            : store.listings
        let now = Date()
        var new: [Listing] = []; new.reserveCapacity(sorted.count)
        var earlier: [Listing] = []; earlier.reserveCapacity(sorted.count)
        for l in sorted {
            if l.isNew(asOf: now) { new.append(l) } else { earlier.append(l) }
        }
        cachedSorted = sorted
        cachedNew = new
        cachedEarlier = earlier
    }

    private var updatedAgoText: String {
        guard let last = store.lastUpdated else { return "just now" }
        let interval = Date().timeIntervalSince(last)
        if interval < 5 { return "just now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    private struct FilterChipModel: Identifiable {
        let id = UUID()
        let label: String
        let active: Bool
        let mono: Bool
        let remove: () -> Void
    }

    private var activeFilterChips: [FilterChipModel] {
        var chips: [FilterChipModel] = []
        if !searchText.isEmpty {
            chips.append(.init(label: "Search: \(searchText)", active: true, mono: false) {
                searchText = ""
                searchDraft = ""
                Task { await fetchWithCurrentFilters() }
            })
        }
        if !selectedStatus.isEmpty {
            chips.append(.init(label: shortStatusLabel(selectedStatus), active: true, mono: false) {
                selectedStatus = ""
                Task { await fetchWithCurrentFilters() }
            })
        }
        for city in selectedCities {
            chips.append(.init(label: city, active: false, mono: false) {
                selectedCities.removeAll { $0 == city }
                Task { await fetchWithCurrentFilters() }
            })
        }
        for source in selectedSources {
            chips.append(.init(label: sourceShortLabel(source), active: false, mono: true) {
                selectedSources.removeAll { $0 == source }
                Task { await fetchWithCurrentFilters() }
            })
        }
        for t in selectedTypes {
            chips.append(.init(label: t, active: false, mono: false) {
                selectedTypes.removeAll { $0 == t }
                Task { await fetchWithCurrentFilters() }
            })
        }
        if !selectedContract.isEmpty {
            chips.append(.init(label: selectedContract, active: false, mono: false) {
                selectedContract = ""
                Task { await fetchWithCurrentFilters() }
            })
        }
        if !selectedEnergy.isEmpty {
            chips.append(.init(label: "Energy ≥ \(selectedEnergy)", active: false, mono: true) {
                selectedEnergy = ""
                Task { await fetchWithCurrentFilters() }
            })
        }
        return chips
    }

    private func shortStatusLabel(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("available to book") { return "Book" }
        if s.contains("lottery") { return "Lottery" }
        if s.contains("reserved") { return "Reserved" }
        if s.contains("rented") { return "Rented" }
        if s.contains("not available") { return "Unavailable" }
        return raw
    }

    private func clearAllFilters() {
        selectedStatus = ""
        selectedSources = []
        selectedCities = []
        selectedTypes = []
        selectedContract = ""
        selectedEnergy = ""
        searchText = ""
        searchDraft = ""
        Task { await fetchWithCurrentFilters() }
    }

    private func applySearch() {
        let trimmed = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != searchText else { return }
        searchText = trimmed
        Task { await fetchWithCurrentFilters() }
    }

    private var activeFilterCount: Int {
        ([selectedStatus].filter { !$0.isEmpty }.count
         + (searchText.isEmpty ? 0 : 1)
         + (selectedSources.isEmpty ? 0 : 1)
         + (selectedCities.isEmpty ? 0 : 1)
         + (selectedTypes.isEmpty ? 0 : 1)
         + (selectedContract.isEmpty ? 0 : 1)
         + (selectedEnergy.isEmpty ? 0 : 1))
    }

    private var searchButtonTitle: String {
        searchText.isEmpty ? "Search" : "Search: \(searchText)"
    }

    private var filterButtonTitle: String {
        activeFilterCount > 0 ? "Filters (\(activeFilterCount))" : "Filters"
    }

    private func fetchWithCurrentFilters() async {
        // Backend treats single-city cities= as SQL level; multi-city as Python filter
        let sourcesParam = selectedSources.isEmpty ? nil : selectedSources
        let citiesParam = selectedCities.isEmpty ? nil : selectedCities
        await store.fetch(
            city: (selectedCities.count == 1 ? selectedCities[0] : nil),
            status: selectedStatus.nilIfEmpty,
            query: searchText.nilIfEmpty,
            sources: sourcesParam,
            cities: citiesParam,
            types: selectedTypes.isEmpty ? nil : selectedTypes,
            contract: selectedContract.nilIfEmpty,
            energy: selectedEnergy.nilIfEmpty)
    }

    private func sourceShortLabel(_ source: String) -> String {
        Platform.shortName(source)
    }
}

/// 列表页排序选项的**展示**形态。真正的排序在服务端做，这里只负责标题、图标，
/// 以及映射到 `FlatRadarCore.ListingSort`（后端 openapi 的 enum 镜像）。
private enum ListingSortOption: String, CaseIterable, Identifiable {
    case newest
    case priceLow
    case priceHigh
    case availableSoon
    case city
    case name

    var id: String { rawValue }

    /// 对应的服务端排序。`nil` 表示后端没有这个键。
    ///
    /// ⚠️ `.name` 目前是 `nil` —— 后端 1.23.0 的 enum 里没有 `name`
    /// （price / area / energy / first_seen / last_seen / available_from /
    /// city / status / source）。它是唯一还在本地排的选项，因此仍然只排
    /// 已加载的那几页。后端补上 `name` 之后把这里改成 `.init(key: .name, ...)`，
    /// 下面 `sorted(using:)` 的整个 extension 就能删掉。
    var serverSort: FlatRadarCore.ListingSort? {
        switch self {
        case .newest:        return .newestFirst
        case .priceLow:      return .init(key: .price, ascending: true)
        case .priceHigh:     return .init(key: .price, ascending: false)
        case .availableSoon: return .init(key: .availableFrom, ascending: true)
        case .city:          return .init(key: .city, ascending: true)
        case .name:          return nil
        }
    }

    var title: String {
        switch self {
        case .newest: return "Newest"
        case .priceLow: return "Price: Low to High"
        case .priceHigh: return "Price: High to Low"
        case .availableSoon: return "Available Soon"
        case .city: return "City"
        case .name: return "Name"
        }
    }

    var systemImage: String {
        switch self {
        case .newest: return "clock.arrow.circlepath"
        case .priceLow: return "eurosign.arrow.circlepath"
        case .priceHigh: return "eurosign.circle"
        case .availableSoon: return "calendar.badge.clock"
        case .city: return "building.2"
        case .name: return "textformat.abc"
        }
    }
}

private extension Array where Element == Listing {
    func sorted(using sort: ListingSortOption) -> [Listing] {
        switch sort {
        case .newest:
            return sorted { ($0.firstSeen ?? "") > ($1.firstSeen ?? "") }
        case .priceLow:
            return sorted { ($0.priceValue ?? .greatestFiniteMagnitude) < ($1.priceValue ?? .greatestFiniteMagnitude) }
        case .priceHigh:
            return sorted { ($0.priceValue ?? -.greatestFiniteMagnitude) > ($1.priceValue ?? -.greatestFiniteMagnitude) }
        case .availableSoon:
            return sorted { ($0.availableDayKey ?? "9999-99-99") < ($1.availableDayKey ?? "9999-99-99") }
        case .city:
            return sorted { lhs, rhs in
                if lhs.city == rhs.city { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
                return lhs.city.localizedCaseInsensitiveCompare(rhs.city) == .orderedAscending
            }
        case .name:
            return sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ListingFilterSheet: View {
    @Binding var selectedStatus: String
    @Binding var selectedSources: [String]
    @Binding var selectedCities: [String]
    @Binding var selectedTypes: [String]
    @Binding var selectedContract: String
    @Binding var selectedEnergy: String

    let activeFilterCount: Int
    let apply: () -> Void
    let reset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options = FilterOptions.empty
    @State private var isLoadingOptions = false

    /// Expandable sections
    @State private var showCities = false
    @State private var showSources = false
    @State private var showTypes = false

    // ── 未保存变更追踪 ───────────────────────────────────────────────
    // 打开 sheet 时快照初始值；后续比对得 hasUnsavedChanges；
    // dirty 时阻止下滑 dismiss，Cancel 弹 confirmation。
    @State private var initialStatus = ""
    @State private var initialSources: [String] = []
    @State private var initialCities: [String] = []
    @State private var initialTypes: [String] = []
    @State private var initialContract = ""
    @State private var initialEnergy = ""
    @State private var snapshotTaken = false
    @State private var showDiscardConfirm = false

    private var hasUnsavedChanges: Bool {
        guard snapshotTaken else { return false }
        return selectedStatus != initialStatus
            || selectedSources != initialSources
            || selectedCities != initialCities
            || selectedTypes != initialTypes
            || selectedContract != initialContract
            || selectedEnergy != initialEnergy
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isLoadingOptions && options.sources.isEmpty {
                        ProgressView()
                    } else if options.sources.isEmpty {
                        Text("No platforms available").font(.subheadline).foregroundStyle(.secondary)
                    } else if options.sources.count > 6 {
                        DisclosureGroup(isExpanded: $showSources) {
                            sourceRows(choices: options.sources, selection: $selectedSources)
                        } label: {
                            Text(selectedSources.isEmpty ? "All Platforms" : "\(selectedSources.count) selected")
                        }
                    } else {
                        sourceRows(choices: options.sources, selection: $selectedSources)
                    }
                } header: {
                    Label("Platforms", systemImage: "rectangle.3.group.fill")
                }

                // Cities: multi-select
                Section {
                    if isLoadingOptions && options.cities.isEmpty {
                        ProgressView()
                    } else if options.cities.isEmpty {
                        Text("No cities available").font(.subheadline).foregroundStyle(.secondary)
                    } else if options.cities.count > 6 {
                        DisclosureGroup(isExpanded: $showCities) {
                            multiSelectRows(choices: options.cities, selection: $selectedCities)
                        } label: {
                            HStack {
                                Text(selectedCities.isEmpty ? "All Cities" : "\(selectedCities.count) selected")
                                Spacer()
                            }
                        }
                    } else {
                        multiSelectRows(choices: options.cities, selection: $selectedCities)
                    }
                } header: {
                    Label("Cities", systemImage: "building.2.fill")
                }

                // Status: single picker
                Section {
                    Picker("Status", selection: $selectedStatus) {
                        Text("All Statuses").tag("")
                        ForEach(availableStatusesFromOptions, id: \.self) { s in
                            Text(s).tag(s)
                        }
                    }
                } header: {
                    Label("Status", systemImage: "tag.fill")
                }

                // Types: multi-select
                Section {
                    if isLoadingOptions && options.types.isEmpty {
                        ProgressView()
                    } else if options.types.isEmpty {
                        Text("No types available").font(.subheadline).foregroundStyle(.secondary)
                    } else if options.types.count > 6 {
                        DisclosureGroup(isExpanded: $showTypes) {
                            multiSelectRows(choices: options.types, selection: $selectedTypes,
                                        display: FeatureText.displayType)
                        } label: {
                            HStack {
                                Text(selectedTypes.isEmpty ? "All Types" : "\(selectedTypes.count) selected")
                                Spacer()
                            }
                        }
                    } else {
                        multiSelectRows(choices: options.types, selection: $selectedTypes,
                                        display: FeatureText.displayType)
                    }
                } header: {
                    Label("Type", systemImage: "house.lodge")
                }

                // Contract: single picker
                Section {
                    Picker("Contract", selection: $selectedContract) {
                        Text("Any").tag("")
                        ForEach(options.contract, id: \.self) { c in
                            Text(c).tag(c)
                        }
                    }
                } header: {
                    Label("Contract", systemImage: "calendar")
                }

                // Energy: min level picker
                Section {
                    Picker("Min energy label", selection: $selectedEnergy) {
                        Text("Any").tag("")
                        ForEach(options.energy.isEmpty ? energyLabels : options.energy, id: \.self) { label in
                            Text(label).tag(label)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Label("Energy", systemImage: "bolt.fill")
                } footer: {
                    Text("Min B = A/A+/A++/A+++ also accepted; C and worse filtered out.")
                }

                // Reset
                if activeFilterCount > 0 {
                    Section {
                        Button("Reset All Filters", role: .destructive, action: reset)
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasUnsavedChanges {
                            showDiscardConfirm = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: apply)
                }
            }
            // 脏数据时禁用下滑关闭——防止用户误操作丢掉刚改的筛选条件。
            // 强制走 Cancel/Apply 按钮路径（Cancel 会再弹 confirmation）。
            .interactiveDismissDisabled(hasUnsavedChanges)
            .confirmationDialog(
                "Discard filter changes?",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) {
                    // 还原到打开 sheet 那一刻的初始值，避免下次再打开还看到脏数据
                    selectedStatus = initialStatus
                    selectedSources = initialSources
                    selectedCities = initialCities
                    selectedTypes = initialTypes
                    selectedContract = initialContract
                    selectedEnergy = initialEnergy
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            }
            .task {
                // 第一次出现时快照初始 filter 值；后续 sheet 内修改 binding
                // 不会触发再次快照（snapshotTaken 守卫）。
                if !snapshotTaken {
                    initialStatus   = selectedStatus
                    initialSources  = selectedSources
                    initialCities   = selectedCities
                    initialTypes    = selectedTypes
                    initialContract = selectedContract
                    initialEnergy   = selectedEnergy
                    snapshotTaken   = true
                }
                await loadOptions()
            }
        }
    }

    /// Known status values. The backend SQL `WHERE status = ?` matches exactly;
    /// unused values simply return empty results.
    private var availableStatusesFromOptions: [String] {
        ["Available to book", "Available in lottery", "Not available", "Reserved", "Rented"]
    }

    @ViewBuilder
    /// - Parameter display: 后端原值 → 显示文案。默认原样（这张表历来直接显示
    ///   原值）；房型传 `FeatureText.displayType` 剥掉尾部括号注释。勾选和回传
    ///   用的仍然是原值。
    private func multiSelectRows(
        choices: [String],
        selection: Binding<[String]>,
        display: @escaping (String) -> String = { $0 }
    ) -> some View {
        ForEach(choices, id: \.self) { c in
            Toggle(isOn: Binding(
                get: { selection.wrappedValue.contains(c) },
                set: { add in
                    if add {
                        if !selection.wrappedValue.contains(c) {
                            selection.wrappedValue.append(c)
                        }
                    } else {
                        selection.wrappedValue.removeAll { $0 == c }
                    }
                }
            )) {
                Text(verbatim: display(c))
            }
        }
    }

    @ViewBuilder
    private func sourceRows(choices: [String], selection: Binding<[String]>) -> some View {
        ForEach(choices, id: \.self) { source in
            Toggle(isOn: Binding(
                get: { selection.wrappedValue.contains(source) },
                set: { add in
                    if add {
                        if !selection.wrappedValue.contains(source) {
                            selection.wrappedValue.append(source)
                        }
                    } else {
                        selection.wrappedValue.removeAll { $0 == source }
                    }
                }
            )) {
                HStack {
                    Text(sourceShortLabel(source))
                        .font(.system(.caption, design: .monospaced, weight: .heavy))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    Text(sourceDisplayName(source))
                }
            }
        }
    }

    private func sourceShortLabel(_ source: String) -> String {
        Platform.shortName(source)
    }

    private func sourceDisplayName(_ source: String) -> String {
        Platform.displayName(source)
    }

    private func loadOptions() async {
        isLoadingOptions = true
        defer { isLoadingOptions = false }
        do {
            options = try await APIClient.shared.getFilterOptions()
        } catch {
            #if DEBUG
            print("[ListingFilterSheet] loadOptions error: \(error)")
            #endif
        }
    }
}
