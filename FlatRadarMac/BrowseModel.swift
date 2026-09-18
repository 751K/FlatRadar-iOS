import SwiftUI
import FlatRadarCore

/// 一个浏览窗口的全部状态。
///
/// 为什么是**窗口级**而不是全局
/// --------------------------
/// docs/MACOS.md 风险 6 把状态分成三层：应用级（服务器、账户、认证、推送）、
/// 窗口级（当前页、多选、详情焦点、排序、临时筛选、分页、固定比较项）、
/// 可选共享缓存。带查询状态的 ``ListingsStore`` 属于窗口级——两个窗口各排各的序、
/// 各筛各的，共享一个实例会互相覆盖。所以它在这里，不在 `App` 里。
///
/// 选择一律按**稳定 id** 存，不存索引也不存 `Listing` 值：刷新之后数组会整个换掉，
/// 索引失效，值也不再 `==`。
@MainActor
@Observable
final class BrowseModel {

    /// 大页：Mac 的表格要能用 ↑↓ 一路翻到底，分批加载会让键盘浏览卡顿。
    /// 全量 822 条约 57 KB gzip、两个请求，一次拉完更划算。
    let listings = ListingsStore(pageSize: 500)

    /// 侧栏当前选中的那一屏。
    ///
    /// 它在**窗口级**而不是应用级：将来两个窗口可以一个看列表、一个看地图。
    ///
    /// 离开地图时顺手把 ``mapBuilding`` 放掉——否则回到列表点一条房源，
    /// 右栏顶上还挂着地图那栋楼的单元列表。
    ///
    /// ⚠️ 清理写在**这里**，不能写在 `mapBuilding` 自己的 `didSet` 里。
    /// 那样是 `didSet` 里给自己赋值 = 无限递归：`didSet` 每次赋值都触发，
    /// 不管值变没变。第一版就是那么写的，实测栈爆到 20963 层 SIGSEGV。
    /// 在这里赋值是安全的：改 `mapBuilding` 不会回头触发 `section` 的 `didSet`。
    var section: SidebarSection = .listings {
        didSet {
            if section != .map { mapBuilding = nil }
            if section != .calendar { calendarDay = nil }
            if section != .alerts {
                focusedAlert = nil
                focusedAlertRow = nil
            }
            if section != .stats { statsChart = nil }
        }
    }

    /// `Table` 的多选。
    var selection: Set<Listing.ID> = []

    /// 详情面板当前展示的那一条。
    ///
    /// 不直接用 `selection.first`：多选时"选中集合"和"详情焦点"是两件事——
    /// ⌘ 点第二条时详情该跟到新点的那条，而 `Set` 没有顺序。
    var focused: Listing.ID?

    /// 固定下来并排比较的两套。按 id 存，最多两个。
    var pinned: [Listing.ID] = []

    /// 地图上当前选中的那栋楼。
    ///
    /// inspector 是三屏共用的（见 ``MainWindow``），所以「现在该显示什么」这件事
    /// 由各屏往这里写。地图写楼盘，右栏据此在详情上面多列一段"这栋楼里的单元"。
    /// 什么时候清掉见 ``section``。
    var mapBuilding: MapBuilding?

    /// 日历上当前选中的那一天，**连着那天的房源一起**。
    ///
    /// 和 ``mapBuilding`` 同一个角色：inspector 是三屏共用的，「现在该显示什么」
    /// 由各屏往这里写。日历写一个日期，右栏据此列出当天起租的房源。
    ///
    /// ⚠️ 清理同样写在 ``section`` 的 `didSet` 里，**不能**写在自己的 `didSet`
    /// 里——那是在 `didSet` 里给自己赋值，等于无限递归（`didSet` 每次赋值都
    /// 触发，不管值变没变）。`mapBuilding` 第一版就那么写的，实测栈爆到
    /// 20963 层 SIGSEGV。
    var calendarDay: CalendarDay?

    /// Stats 屏选中的那张图，右栏据此列完整明细。
    ///
    /// 和 ``mapBuilding`` / ``calendarDay`` / ``focusedAlertRow`` 同一个角色：
    /// 右栏是四屏共用的，「现在该显示什么」由各屏往这里写。
    ///
    /// ⚠️ 清理同样写在 ``section`` 的 `didSet` 里，**不能**写在自己的 `didSet`
    /// 里——那是无限递归（`didSet` 每次赋值都触发，不管值变没变），
    /// `mapBuilding` 第一版就那么写的，实测栈爆到 20963 层 SIGSEGV。
    var statsChart: StatsSelection?

    /// 通知屏当前选中那条的 id。
    ///
    /// 和 ``mapBuilding`` / ``calendarDay`` 同一个角色；清理同样写在 ``section``
    /// 的 `didSet` 里，不能写在自己的 `didSet` 里（那是无限递归，见上）。
    var focusedAlert: Int?

    /// 选中那条通知本身。
    ///
    /// 存**整行**而不是让 ``InspectorPane`` 自己去 store 里查：右栏是三屏共用的，
    /// 多认一个 store 就多一层耦合——和 ``calendarDay`` 存 ``CalendarDay``
    /// 而不是存 `Date` 是同一个理由。由 ``AlertsPane`` 在选中时写进来。
    var focusedAlertRow: AlertRow?

    /// 选中一条通知：右栏上半是这条通知，下半是它说的那套房。
    ///
    /// **详情焦点跟着换过去；换不过去就清空，不能留着。** 原先房源不在已加载的
    /// 那批里时 `focused` 保持不动，理由是"总比空白好"——结果右栏上半是新通知、
    /// 下半是上一套房的价格、详情和操作按钮，⌘D / Open on Platform 也还作用在
    /// 那套旧房上（代码审查 P2）。上下两截说的不是同一套房，比空白糟得多。
    ///
    /// 不在已加载那批里的，右栏下半给「Open Listing」按 id 单独开窗去取，
    /// 见 ``InspectorPane``。系统通知没有房源，`focused` 同样清空。
    func focusAlert(_ row: AlertRow?) {
        focusedAlert = row?.id
        focusedAlertRow = row
        focused = row.flatMap { listing($0.listingID)?.id }
    }

    /// 表格列头的排序状态。
    ///
    /// ⚠️ 这里的 comparator **不排序**，只是个标签——真正的排序在服务端做
    /// （见 ``ListingColumnComparator``）。SwiftUI 用它画列头的箭头，我们用它
    /// 的 `key` 换算出 `sort=` 参数。
    var sortOrder: [ListingColumnComparator] = [
        ListingColumnComparator(key: .firstSeen, order: .reverse)
    ]

    /// ⌘F 的计数信号。菜单命令改不了视图里的 `@FocusState`，所以走"自增一个数、
    /// 视图 onChange 把焦点打过去"这条路。用计数而不是 Bool：连按两次 ⌘F 也要生效。
    private(set) var searchFocusRequests = 0

    func requestSearchFocus() { searchFocusRequests += 1 }

    /// 「在地图上定位这一条」的待办。``MapPane`` 接住它飞过去，然后清掉。
    ///
    /// 为什么要经过 model 传：地图的相机是 `MapPane` 自己的 `@State`，列表那边的
    /// 右键菜单够不着；而把相机提到 `BrowseModel` 里又会让每次平移缩放都触发
    /// 整个窗口重算（那正是上次让右栏数字乱动的成因）。所以传的是**意图**，
    /// 不是相机——一个 id，由地图自己决定怎么飞。
    ///
    /// 带一个自增序号：连着对同一套房点两次「Show on Map」也要生效。只存 id 的话
    /// 第二次赋的是同一个值，`onChange` 不触发。
    private(set) var mapFocusRequest: (id: Listing.ID, seq: Int)?

    /// 右键菜单的「Show on Map」。先切屏再写请求——反过来写的话，`section` 的
    /// `didSet` 会在切到 `.map` 之前先把 `mapBuilding` 清掉，而地图正要用它。
    func locateOnMap(_ listing: Listing) { locateOnMap(id: listing.id) }

    /// 只有 id 的那条路：`h2smonitor://map/<id>` 点进来时，手上没有 `Listing`
    /// （那条房源还不一定在这个窗口加载过）。地图那边本来也只用 id 去找楼。
    func locateOnMap(id: Listing.ID) {
        section = .map
        mapFocusRequest = (id, (mapFocusRequest?.seq ?? 0) + 1)
    }

    /// 地图处理完之后自己清掉，免得再切回地图屏时又飞一次。
    func clearMapFocusRequest() { mapFocusRequest = nil }

    /// 表格上方的即时筛选框（⌘F 聚焦）。**本地**过滤已加载的全量结果，
    /// 不是服务端的 `q`——全量已经在手上，本地过滤是即时的，没有网络往返。
    var searchText = ""

    /// 「All filters」那块展开没有。见 ``FilterPanel``。
    var showFilterPanel = false

    /// 面板里勾的那些条件。搜索框是独立的一条，不在这里面——它有自己的输入框和
    /// ⌘F，语义也不同（搜的是地址/城市/楼盘的文本，不是维度）。
    var query = ListingQuery()

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !query.isEmpty
    }

    func clearFilters() {
        searchText = ""
        query = ListingQuery()
    }

    /// 筛选条上那一排**带值的 token**。
    ///
    /// 设计稿 t3 的做法：每个生效的条件是一个写着当前值的小块，而不是一排永远
    /// 长一样的下拉框——扫一眼就知道现在筛的是什么，不用逐个点开确认。
    ///
    /// 一个**维度**一个 token，不是一个选项一个：勾了五个城市就出一个
    /// `Amsterdam +4`，点 ✕ 是把整个维度清掉。一条一个的话筛得稍微细一点，
    /// 这一排就会横着排到屏幕外，而它存在的意义正是"一眼扫完现在筛的是什么"。
    var activeFilterTokens: [FilterToken] {
        var out: [FilterToken] = []
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            out.append(FilterToken(id: "search", label: "“\(q)”") { [weak self] in
                self?.searchText = ""
            })
        }
        func setToken<T: Hashable>(_ id: String,
                                   _ keyPath: WritableKeyPath<ListingQuery, Set<T>>,
                                   _ label: (T) -> String) {
            let values = query[keyPath: keyPath]
            guard let first = values.map(label).sorted().first else { return }
            let text = values.count == 1 ? first : "\(first) +\(values.count - 1)"
            out.append(FilterToken(id: id, label: text) { [weak self] in
                self?.query[keyPath: keyPath] = []
            })
        }
        setToken("city", \.cities) { $0 }
        setToken("source", \.sources) { Platform.shortName($0) }
        setToken("type", \.types) { $0 }
        setToken("energy", \.energy) { $0 }
        setToken("status", \.statuses) { Theme.shortStatusLabel($0) ?? $0.label }
        if let v = query.maxRent {
            out.append(FilterToken(id: "rent", label: "≤ €\(Int(v))") { [weak self] in
                self?.query.maxRent = nil
            })
        }
        if let v = query.minArea {
            let n = v == v.rounded() ? String(Int(v)) : String(v)
            out.append(FilterToken(id: "area", label: "≥ \(n) m²") { [weak self] in
                self?.query.minArea = nil
            })
        }
        if query.datedOnly {
            out.append(FilterToken(id: "dated", label: "Has a move-in date") { [weak self] in
                self?.query.datedOnly = false
            })
        }
        return out
    }

    // MARK: - 派生

    /// 所有影响本地结果的输入。视图以它作为 task id，变化时取消旧任务。
    nonisolated struct RowsInput: Equatable, Sendable {
        let listings: [Listing]
        let query: ListingQuery
        let search: String
        var needsFiltering: Bool { !query.isEmpty || !search.isEmpty }
    }

    var rowsInput: RowsInput {
        RowsInput(listings: listings.listings, query: query,
                  search: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var completedRows: (input: RowsInput, rows: [Listing])?
    @ObservationIgnored private(set) var rowsComputeCount = 0
    @ObservationIgnored var filterRows: @Sendable (RowsInput) async throws -> [Listing] = BrowseModel.filter

    var isFiltering: Bool {
        let input = rowsInput
        return input.needsFiltering && completedRows?.input != input
    }

    /// body、计数和键盘导航只读结果，不执行过滤。待计算时不暴露旧条件的行。
    var rows: [Listing] {
        let input = rowsInput
        guard input.needsFiltering else { return input.listings }
        guard completedRows?.input == input else { return [] }
        return completedRows?.rows ?? []
    }

    func updateRows(debounce: Bool = true) async {
        let input = rowsInput
        guard input.needsFiltering else {
            completedRows = nil
            reconcileSelection()
            return
        }
        guard completedRows?.input != input else { return }
        do {
            if debounce, !input.search.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
            try Task.checkCancellation()
            rowsComputeCount += 1
            let result = try await filterRows(input)
            guard !Task.isCancelled, rowsInput == input else { return }
            completedRows = (input, result)
            reconcileSelection()
        } catch is CancellationError {
            // 新输入、切屏或关窗取消了这次工作。
        } catch {
            assertionFailure("Unexpected local filter error: \(error)")
        }
    }

    @concurrent
    nonisolated static func filter(_ input: RowsInput) async throws -> [Listing] {
        var result: [Listing] = []
        result.reserveCapacity(input.listings.count)
        for (index, listing) in input.listings.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard input.query.isEmpty || input.query.matches(listing) else { continue }
            let q = input.search
            if q.isEmpty || listing.name.localizedCaseInsensitiveContains(q)
                || listing.city.localizedCaseInsensitiveContains(q)
                || (listing.buildingText ?? "").localizedCaseInsensitiveContains(q) {
                result.append(listing)
            }
        }
        return result
    }

    func listing(_ id: Listing.ID?) -> Listing? {
        guard let id else { return nil }
        return listings.listings.first { $0.id == id }
    }

    /// 固定项可能在刷新后消失（房源下架）。**不自动换成另一套**——
    /// 那会让用户以为自己还在比较原来那两套。返回 nil 由界面显示"已不可用"。
    var pinnedListings: [(id: Listing.ID, listing: Listing?)] {
        pinned.map { ($0, listing($0)) }
    }

    var isPinned: (Listing.ID) -> Bool { { [pinned] in pinned.contains($0) } }

    // MARK: - 动作

    func load() async {
        await listings.fetch()
        await listings.loadAllPages()
        reconcileSelection()
    }

    func reload() async {
        await listings.refresh()
        await listings.loadAllPages()
        reconcileSelection()
    }

    /// 列头点击 → 换排序。
    ///
    /// 全量已经在手（Mac 的常态）：按服务端同一套规则**本地重排**，不发请求。
    /// 原先这里总是从第一页重拉、再顺序拉完所有页——两千条每页五百就是四个请求，
    /// 来回切几次排序就是几倍的请求和解码（代码审查）。顺序和服务端逐条一致，
    /// 见 `ServerListingOrder`。
    ///
    /// 没拉全（还在翻页、翻页失败）才去服务端排：那时本地只能排已加载的那几页，
    /// 正是 iOS 当年那个 bug。
    func applySortOrder() async {
        guard let c = sortOrder.first else { return }
        if listings.reorderLocally(c.serverSort) {
            reconcileSelection()
            return
        }
        await listings.setSort(c.serverSort)
        await listings.loadAllPages()
        reconcileSelection()
    }

    /// 固定 / 取消固定。满两个时替换最早那个。
    func togglePin(_ id: Listing.ID) {
        if let i = pinned.firstIndex(of: id) {
            pinned.remove(at: i)
        } else if pinned.count >= 2 {
            pinned.removeFirst()
            pinned.append(id)
        } else {
            pinned.append(id)
        }
    }

    // MARK: - 键盘浏览

    /// 把焦点移到上 / 下一条。
    ///
    /// 表格自己在有键盘焦点时就认 ↑↓（底下是 NSTableView），**这个方法是给
    /// 焦点不在表格上的时候用的**——最主要是搜索框：边打字筛选边用 ↑↓ 翻结果，
    /// 手不用离开键盘。Spotlight、Alfred 都是这个手感。
    ///
    /// ⚠️ 走的是 ``rows`` 而不是 `listings.listings`：搜索之后表格里只剩匹配的
    /// 那些行，↑↓ 必须在**看得见的那个集合**里走。拿全量算的话会跳到一条屏幕上
    /// 根本没有的房源上，右边详情变了、左边却没有任何东西高亮。
    /// - Parameter extending: ⇧↑ / ⇧↓ —— 把新落点**并进**选择集而不是替换它。
    func moveSelection(by delta: Int, extending: Bool = false) {
        guard !isFiltering else { return }
        let visible = rows
        guard !visible.isEmpty else { return }

        let index: Int
        if let focused, let cur = visible.firstIndex(where: { $0.id == focused }) {
            // 到头就停住，不回绕。列表回绕会让人失去"我在哪儿"的感觉——
            // 按住 ↓ 本来是想到底，结果又从头开始。
            index = min(max(cur + delta, 0), visible.count - 1)
        } else {
            // 还没有焦点：↓ 落在第一条，↑ 落在最后一条。
            index = delta > 0 ? 0 : visible.count - 1
        }

        let id = visible[index].id
        focused = id
        if extending {
            selection.insert(id)
        } else {
            selection = [id]
        }
    }

    /// ⇧ 点选：把 `from` 到 `to` 之间整段选上（含两端）。
    ///
    /// 走的同样是 ``rows``——用户看见的是筛选后的那些行，"这两条之间"指的是
    /// **屏幕上**的之间，不是全量数组里的之间。
    func selectRange(from anchor: Listing.ID, to target: Listing.ID) {
        guard !isFiltering else { return }
        let visible = rows
        guard let a = visible.firstIndex(where: { $0.id == anchor }),
              let b = visible.firstIndex(where: { $0.id == target }) else {
            selection = [target]
            focused = target
            return
        }
        let range = a <= b ? a...b : b...a
        selection = Set(visible[range].map(\.id))
        // 焦点落在**点的那一条**，不是区间端点：下一次 ⇧ 点要以它为锚。
        focused = target
    }

    /// 没有任何选中时选上第一条。
    ///
    /// 首屏必须有一条被选中，否则 ↑↓ 没有起点，而且右边 inspector 一片
    /// "No Selection"——用户看到的是一个"还没加载完"的界面，其实数据早就来了。
    func selectFirstRowIfNeeded() {
        guard !isFiltering else { return }
        guard focused == nil, let first = rows.first else { return }
        focused = first.id
        selection = [first.id]
    }

    /// 刷新之后把已经不存在的选择清掉，仍在的保留。
    ///
    /// 完成判据里的「刷新后选中状态稳定」指的就是这个：不是"保留一切"，
    /// 也不是"全清"，而是按 id 对齐。固定比较项**不清**——它要显示成
    /// "已不可用"，清掉的话用户不会知道自己比的那套没了。
    ///
    /// 对齐的基准是 ``rows``（当前可见的行），不是全部已加载的：搜索框里有字的
    /// 时候，选中一条被筛掉的房源等于选中了一条看不见的行。
    func reconcileSelection() {
        guard !isFiltering else { return }
        let visible = rows
        let live = Set(visible.map(\.id))
        selection.formIntersection(live)
        if let focused, !live.contains(focused) { self.focused = nil }
        if focused == nil { focused = selection.first }
        // 焦点被筛没了就落到第一条可见行上，而不是留空。
        selectFirstRowIfNeeded()
    }
}

/// 表格列头用的排序标签。
///
/// **它不做比较。** `compare` 恒返回 `.orderedSame`：真正的顺序要么来自服务端
/// （`GET /listings?sort=`），要么在全量已在手时由 `ListingsStore.reorderLocally`
/// 按服务端同一套规则重排（`ServerListingOrder`）。SwiftUI 要求列头带一个
/// `SortComparator` 才肯画箭头、才肯把点击反馈到 `sortOrder`，所以这里提供一个
/// 只携带 `key` 的空壳。
///
/// 写成"真比较"反而是错的：那是另一套规则，和服务端的顺序对不上（未知值放哪、
/// 并列怎么排），一刷新行就跳。
struct ListingColumnComparator: SortComparator, Hashable {

    var key: ListingSortKey
    var order: SortOrder = .forward

    func compare(_ lhs: Listing, _ rhs: Listing) -> ComparisonResult { .orderedSame }

    var serverSort: ListingSort {
        ListingSort(key: key, ascending: order == .forward)
    }
}

/// 筛选条上的一个 token：显示当前值，点 ✕ 移除。
struct FilterToken: Identifiable {
    let id: String
    let label: String
    let remove: () -> Void
}
