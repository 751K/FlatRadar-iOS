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

    /// 表格上方的即时筛选框（⌘F 聚焦）。**本地**过滤已加载的全量结果，
    /// 不是服务端的 `q`——全量已经在手上，本地过滤是即时的，没有网络往返。
    var searchText = ""

    /// 「All filters」那块展开没有。
    ///
    /// 面板本身还没做（见 `FilterPanel`）。位置先占住，因为它决定表格从哪一行
    /// 开始——等真面板铺进来时不用再动一次布局。
    var showFilterPanel = false

    /// 现在只有搜索框一个筛选条件。等 `FilterPanel` 做完，平台 / 城市 / 价格区间
    /// 这些都要并进来——**它们全部本地算**，因为 822 条已经全在内存里
    /// （见 ``listings`` 的 pageSize 注释）。
    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func clearFilters() {
        searchText = ""
    }

    /// 筛选条上那一排**带值的 token**。
    ///
    /// 设计稿 t3 的做法：每个生效的条件是一个写着当前值的小块，而不是一排永远
    /// 长一样的下拉框——扫一眼就知道现在筛的是什么，不用逐个点开确认。
    ///
    /// 现在只有搜索一个条件。平台 / 城市 / 价格区间那些等 `FilterPanel` 做完再并进来，
    /// **它们全部本地算**（822 条已经在内存里），不用等后端。
    var activeFilterTokens: [FilterToken] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return [FilterToken(id: "search", label: "“\(q)”") { [weak self] in
            self?.searchText = ""
        }]
    }

    // MARK: - 派生

    /// 表格实际显示的行。
    var rows: [Listing] {
        let all = listings.listings
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.city.localizedCaseInsensitiveContains(q)
                || ($0.buildingText ?? "").localizedCaseInsensitiveContains(q)
        }
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

    /// 列头点击 → 换服务端排序 → 从第一页重拉。
    ///
    /// 不能只把已加载的重排：那是 iOS 上刚修掉的那个 bug 的 Mac 版本。
    func applySortOrder() async {
        guard let c = sortOrder.first else { return }
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
/// **它不做比较。** `compare` 恒返回 `.orderedSame`，因为排序已经由服务端完成
/// （`GET /listings?sort=`，见 `FlatRadarCore.ListingSort`）。SwiftUI 的 `Table`
/// 要求列头带一个 `SortComparator` 才肯画箭头、才肯把点击反馈到 `sortOrder`，
/// 所以这里提供一个只携带 `key` 的空壳。
///
/// 写成"真比较"反而是错的：那样点列头会先本地排一遍已加载的、再被服务端结果覆盖，
/// 中间闪一下；而且一旦将来分页没拉全，本地那次排序就是错的顺序。
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
