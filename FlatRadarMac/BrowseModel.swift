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

    /// `Table` 的多选。
    var selection: Set<Listing.ID> = []

    /// 详情面板当前展示的那一条。
    ///
    /// 不直接用 `selection.first`：多选时"选中集合"和"详情焦点"是两件事——
    /// ⌘ 点第二条时详情该跟到新点的那条，而 `Set` 没有顺序。
    var focused: Listing.ID?

    /// 固定下来并排比较的两套。按 id 存，最多两个。
    var pinned: [Listing.ID] = []

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

    /// 刷新之后把已经不存在的选择清掉，仍在的保留。
    ///
    /// 完成判据里的「刷新后选中状态稳定」指的就是这个：不是"保留一切"，
    /// 也不是"全清"，而是按 id 对齐。固定比较项**不清**——它要显示成
    /// "已不可用"，清掉的话用户不会知道自己比的那套没了。
    private func reconcileSelection() {
        let live = Set(listings.listings.map(\.id))
        selection.formIntersection(live)
        if let focused, !live.contains(focused) { self.focused = nil }
        if focused == nil { focused = selection.first }
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
