import SwiftUI
import AppKit
import FlatRadarCore

/// Phase 2 的主界面：左表格 / 右详情。
///
/// 立意在文档里写得很清楚——Mac 是指针 + 键盘的机器，租房本质是**比较**任务，
/// 而比较需要把候选并排放。所以这一屏的三件事是：表格能按列排序、↑↓ 能连续翻、
/// 两套候选能固定下来并排看。地图和日历排在后面。
struct BrowseWindow: View {

    @Environment(AuthStore.self) private var auth
    @State private var model = BrowseModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            listPane
                .navigationSplitViewColumnWidth(min: 520, ideal: 760)
        } detail: {
            DetailPane(model: model)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        }
        .navigationTitle("FlatRadar")
        .toolbar { toolbarItems }
        .task { await model.load() }
        .focusedSceneValue(\.browseModel, model)
        .onChange(of: searchRequestToken) { _, _ in searchFocused = true }
    }

    // MARK: - 左：表格

    private var listPane: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
            Divider()
            statusBar
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.listings.isLoading && model.listings.listings.isEmpty {
            centered { ProgressView("Loading listings…") }
        } else if let err = model.listings.errorMessage, model.listings.listings.isEmpty {
            centered {
                // 完成判据：空列表 / 加载失败要有明确状态**和重试入口**。
                ContentUnavailableView {
                    Label(loadErrorTitle, systemImage: loadErrorIcon)
                } description: {
                    Text(err)
                } actions: {
                    Button("Try Again") { Task { await model.reload() } }
                }
            }
        } else if model.rows.isEmpty {
            centered {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "No Listings" : "No Matches",
                    systemImage: model.searchText.isEmpty ? "house" : "magnifyingglass",
                    description: Text(model.searchText.isEmpty
                                      ? "Nothing matches the current filter."
                                      : "No listing matches “\(model.searchText)”."))
            }
        } else {
            table
        }
    }

    private var table: some View {
        @Bindable var model = model
        return Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            // 地址列不可排序：后端 1.23.0 的 sort enum 里没有 `name`。
            // 与其本地排一遍（那就只排得到已加载的），不如不给这个列头箭头。
            TableColumn("Address") { l in
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.name).lineLimit(1)
                    if let b = l.buildingText, !b.isEmpty {
                        Text(b).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 160, ideal: 240)

            TableColumn("City", sortUsing: ListingColumnComparator(key: .city)) { l in
                Text(l.city)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Price", sortUsing: ListingColumnComparator(key: .price)) { l in
                Text(l.priceRaw ?? "—").monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            TableColumn("Area", sortUsing: ListingColumnComparator(key: .area)) { l in
                Text(l.normalizedAreaText ?? "—").monospacedDigit()
            }
            .width(min: 70, ideal: 90)

            // 房型同样没有服务端 sort 键。
            TableColumn("Type") { l in Text(l.typeText ?? "—") }
                .width(min: 70, ideal: 100)

            TableColumn("Energy", sortUsing: ListingColumnComparator(key: .energy)) { l in
                Text(l.energyText ?? "—")
            }
            .width(min: 60, ideal: 70)

            TableColumn("Platform", sortUsing: ListingColumnComparator(key: .source)) { l in
                Text(Platform.displayName(l.source))
            }
            .width(min: 90, ideal: 120)

            TableColumn("Status", sortUsing: ListingColumnComparator(key: .status)) { l in
                Label {
                    Text(ListingStatus.from(l.status).label)
                } icon: {
                    Circle().fill(ListingStatus.from(l.status).color).frame(width: 7, height: 7)
                }
            }
            .width(min: 110, ideal: 140)

            TableColumn("Available",
                        sortUsing: ListingColumnComparator(key: .availableFrom)) { l in
                Text(l.availableFrom.map(ServerTime.displayDate) ?? "—")
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: Listing.ID.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            // 双击 = 在平台原站打开
            if let l = model.listing(ids.first) { openOriginal(l) }
        }
        // ↑↓ 走的是 Table 自带的选择移动；这里把「选中」翻译成「详情焦点」。
        // 不直接用 selection.first：Set 没有顺序，多选时详情会乱跳。
        .onChange(of: model.selection) { old, new in
            if let added = new.subtracting(old).first {
                model.focused = added
            } else if new.count == 1 {
                model.focused = new.first
            } else if new.isEmpty {
                model.focused = nil
            }
        }
        .onChange(of: model.sortOrder) { _, _ in
            Task { await model.applySortOrder() }
        }
    }

    // MARK: - 筛选条与状态条

    private var filterBar: some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("Filter by address, building or city", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            // 完成判据：「排序范围准确可见」。全量拉完时说清楚是全部；
            // 没拉完（分页失败）时必须说明排序只覆盖已加载的部分。
            Text(rangeText)
                .font(.callout)
                .foregroundStyle(model.listings.loadMoreFailed ? .orange : .secondary)
            if model.listings.loadMoreFailed {
                Button("Retry") { Task { await model.reload() } }
                    .buttonStyle(.link)
            }
            Spacer()
            if !model.pinned.isEmpty {
                Text("\(model.pinned.count) pinned").font(.callout).foregroundStyle(.secondary)
            }
            if model.listings.isLoading || model.listings.isLoadingMore {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var rangeText: String {
        let store = model.listings
        let shown = model.rows.count
        if store.loadMoreFailed {
            return "已加载 \(store.listings.count) / 共 \(store.total) 条 —— "
                 + "分页失败，排序只覆盖已加载的部分"
        }
        if model.searchText.isEmpty {
            return "\(store.total) listings, sorted by \(sortLabel)"
        }
        return "\(shown) of \(store.total) match, sorted by \(sortLabel)"
    }

    private var sortLabel: String {
        guard let c = model.sortOrder.first else { return "default order" }
        let dir = c.order == .forward ? "↑" : "↓"
        return "\(c.key.rawValue) \(dir)"
    }

    // MARK: - 工具栏与菜单

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem {
            Button { Task { await model.reload() } } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .disabled(model.listings.isLoading)
        }
        ToolbarItem {
            Button {
                if let f = model.focused { model.togglePin(f) }
            } label: {
                Label("Pin for comparison", systemImage: "pin")
            }
            .disabled(model.focused == nil)
        }
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<Listing.ID>) -> some View {
        if let l = model.listing(ids.first) {
            Button(model.pinned.contains(l.id) ? "Unpin" : "Pin for Comparison") {
                model.togglePin(l.id)
            }
            Divider()
            Button("Open on \(Platform.displayName(l.source))") { openOriginal(l) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(l.url, forType: .string)
            }
        }
    }

    private func openOriginal(_ l: Listing) {
        guard let url = URL(string: l.url) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 杂项

    private var loadErrorTitle: String {
        model.listings.lastError?.errorDescription ?? "Unable to Load"
    }
    private var loadErrorIcon: String {
        model.listings.lastError?.systemImage ?? "wifi.slash"
    }

    /// ⌘F 通过 focusedSceneValue 传下来的计数，变了就把焦点打到筛选框。
    private var searchRequestToken: Int { model.searchFocusRequests }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
