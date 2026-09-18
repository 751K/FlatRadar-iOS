import Foundation

@MainActor
@Observable
public final class ListingsStore {

    /// 隐式 init 随 `public` 一起变成 internal，宿主 app 构造不了。
    ///
    /// `pageSize` 可注入：iOS 是无限滚动的列表，一页 50 条正好；Mac 的表格要能
    /// 用 ↑↓ 一路翻到底，分批加载会让键盘浏览断断续续，所以那边用大页一次拉完
    /// （实测全量 822 条约 57 KB gzip、两个请求）。默认值保持 50，iOS 行为不变。
    public init(pageSize: Int = 50) {
        self.pageSize = pageSize
        self.loadPage = { r in
            try await APIClient.shared.getListings(
                city: r.city, status: r.status, query: r.query,
                limit: r.limit, offset: r.offset,
                sources: r.sources, cities: r.cities, types: r.types,
                contract: r.contract, energy: r.energy, sort: r.sort)
        }
    }

    /// 一页房源请求的全部参数。
    nonisolated struct PageRequest: Equatable, Sendable {
        var city: String?, status: String?, query: String?
        var limit: Int, offset: Int
        var sources: [String]?, cities: [String]?, types: [String]?
        var contract: String?, energy: String?
        var sort: ListingSort?
    }

    /// 真正发请求的那一步。默认走 ``APIClient``。
    ///
    /// 留成可换的闭包是给测试的：这个 store 的 bug 全是「两个请求**谁先回来**」
    /// 的问题（翻页途中刷新、刷新途中又刷新），真网络上摆不出那个先后顺序。
    /// 测试换成一个能把请求**扣住**、按指定顺序放行的闭包（`ListingsStorePagingTests`）。
    @ObservationIgnored var loadPage: (PageRequest) async throws -> ListingsResponse
    public var listings: [Listing] = []
    public var total = 0
    public var isLoading = false
    public var isLoadingMore = false
    public var errorMessage: String?
    public var lastError: APIError?
    public var isFiltered = false
    /// 最近一次成功 fetch 的本地时间戳 — 用于 ListingsView 顶部 "updated 2m ago" 心跳条。
    public var lastUpdated: Date?

    private let pageSize: Int

    // Current filter state
    private var currentCity: String?
    private var currentStatus: String?
    private var currentQuery: String?
    private var currentSources: [String] = []
    private var currentCities: [String] = []
    private var currentTypes: [String] = []
    private var currentContract: String?
    private var currentEnergy: String?

    /// 当前排序。发给后端，**只在全量已在手时**才允许本地重排——只拉了几页时本地
    /// 排出来的是「已加载结果里最便宜的」而不是「全部里最便宜的」。
    /// 见 ``ListingSort``、``reorderLocally(_:)``。
    public private(set) var sort: ListingSort = .newestFirst

    /// 已收录的 id，用于跨页去重。
    ///
    /// 后端 1.23.0 起对每次查询追加 `, id ASC` 兜底，翻页本该是稳定的。
    /// 这里仍然去重，是因为「稳定」的前提是两次请求之间数据没变，而扫描器随时
    /// 在写库。重复项的表现是列表里同一套房出现两次，而 `Table` 用 id 做
    /// `Identifiable`，重复 id 会让 SwiftUI 的 diff 出乱子。
    private var seenIDs: Set<String> = []

    /// 分页失败了。
    ///
    /// 原先 `loadMore` 的 catch 是空的，注释写着"用户可以下拉刷新"——但界面上
    /// 没有任何提示说这一页没加载成功，用户只会觉得列表到底了。
    /// Phase 2 的完成判据要求"分页失败有明确状态及重试入口"。
    public private(set) var loadMoreFailed = false

    /// 每次 fetch / loadMore 自增；返回数据时比对，只接受最新一代的结果。
    /// 防止用户飞速改 filter 时旧请求的响应覆盖新结果。
    private var fetchGeneration: UInt64 = 0

    public var hasMore: Bool { listings.count < total }

    /// 启动预热和页面首次出现共用此入口；刷新/改筛选仍走 fetch/refresh。
    public func loadIfNeeded() async {
        guard lastUpdated == nil, listings.isEmpty, !isLoading else { return }
        await refresh()
    }

    public func fetch(city: String? = nil, status: String? = nil, query: String? = nil,
               sources: [String]? = nil, cities: [String]? = nil, types: [String]? = nil,
               contract: String? = nil, energy: String? = nil,
               sort: ListingSort? = nil) async {
        if let sort { self.sort = sort }
        currentCity = city
        currentStatus = status
        currentQuery = query
        currentSources = sources ?? []
        currentCities = cities ?? []
        currentTypes = types ?? []
        currentContract = contract
        currentEnergy = energy
        isLoading = true
        errorMessage = nil
        fetchGeneration &+= 1
        let myGen = fetchGeneration
        // 正在飞的那一页属于**旧**结果集，它回来时会被代号挡掉、什么都不写
        // （见 ``loadMore()``）。所以"正在翻页"这把锁在这里就交还给新结果集——
        // 否则新结果集要等一个注定作废的请求回来才能翻页，而它要是一直不回来
        // （超时 60s），这段时间里新结果集一页都翻不了。
        isLoadingMore = false
        do {
            let resp = try await loadPage(PageRequest(
                city: city, status: status, query: query,
                limit: pageSize, offset: 0,
                sources: sources, cities: cities, types: types,
                contract: contract, energy: energy, sort: self.sort))
            // 期间又被 fetch 一次 → 当前响应已过期，整体丢弃，不写 state。
            guard myGen == fetchGeneration else { return }
            // 第一页重置去重表——换排序 / 换筛选就是一份全新的结果集。
            seenIDs = Set(resp.items.map(\.id))
            listings = resp.items
            total = resp.total
            loadMoreFailed = false
            isFiltered = resp.filtered ?? false
            lastUpdated = Date()
        } catch {
            guard myGen == fetchGeneration else { return }
            // 被取消不是失败——见 Error.isCancellation。
            if !error.isCancellation {
                lastError = error as? APIError
                errorMessage = error.localizedDescription
            }
        }
        if myGen == fetchGeneration { isLoading = false }
    }

    /// 下一页。
    ///
    /// 原先的问题
    /// ----------
    /// 翻页请求在飞的时候刷新或换排序，这页回来时代号已经变了，走
    /// `guard myGen == fetchGeneration else { return }` 提前返回——**跳过了最后那句
    /// `isLoadingMore = false`**。锁就此永远挂着，之后每次 `loadMore()` 都被开头的
    /// `!isLoadingMore` 挡回去：列表停在第一页，而且没有任何报错。
    ///
    /// 同一个过期响应还连带两件事：失败分支不看代号，一页过期请求**失败**了会把
    /// 新结果集标成 `loadMoreFailed`；`loadAllPages()` 看到"这一轮没多出行"就退出，
    /// 退出前同样把新结果集标成失败。
    ///
    /// 现在的规则只有一条：**过期的响应什么都不碰**——不写数据、不标失败、不动锁。
    /// 锁在换结果集那一刻就已经由 ``fetch(city:status:query:sources:cities:types:contract:energy:sort:)``
    /// 交还了，此时它很可能正被新结果集的翻页拿着，旧请求更不能去动它。
    ///
    /// `!isLoading`：第一页还没回来时不翻页。那时 `listings.count` 还是旧结果集的
    /// 条数，拿它当 offset 去请求新结果集，拿回来的是新排序里错位的一页。
    public func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let myGen = fetchGeneration   // load-more 不自增 generation；用 fetch 的代号
        do {
            let resp = try await loadPage(PageRequest(
                city: currentCity, status: currentStatus, query: currentQuery,
                limit: pageSize, offset: listings.count,
                sources: currentSources.isEmpty ? nil : currentSources,
                cities: currentCities.isEmpty ? nil : currentCities,
                types: currentTypes.isEmpty ? nil : currentTypes,
                contract: currentContract, energy: currentEnergy, sort: sort))
            guard myGen == fetchGeneration else { return }
            let fresh = resp.items.filter { seenIDs.insert($0.id).inserted }
            listings.append(contentsOf: fresh)
            total = resp.total
            loadMoreFailed = false
        } catch {
            guard myGen == fetchGeneration else { return }
            if !error.isCancellation { loadMoreFailed = true }
        }
        isLoadingMore = false
    }

    /// 一直翻到底。
    ///
    /// 给 Mac 表格用：完成判据要求「只用键盘跨页浏览」，而按滚动位置触发分页在
    /// `Table` 上很别扭，也会让 ↑↓ 走到边界时卡一下。全量拉完之后 ↑↓ 就是纯本地的。
    ///
    /// `maxPages` 是防跑飞的闸：后端 total 若因为并发写入一直在涨，没有这个上限
    /// 循环不会停。到闸还没拉完就当分页失败处理，界面上要能看见。
    public func loadAllPages(maxPages: Int = 20) async {
        let myGen = fetchGeneration
        var pages = 0
        while hasMore, !loadMoreFailed, pages < maxPages {
            let before = listings.count
            await loadMore()
            // 翻到一半结果集换了（刷新 / 换排序 / 换筛选）：这一轮整个作废，
            // **不**往下走到末尾那句"没翻完就标失败"——那会把新结果集标成失败。
            // 新结果集自己的那一轮由触发刷新的那条路去跑。
            guard myGen == fetchGeneration else { return }
            pages += 1
            // 一页下来一条没多——再循环就是死循环。
            if listings.count == before { break }
        }
        if hasMore && !loadMoreFailed { loadMoreFailed = true }
    }

    /// 结果集已经**全部**在手时换排序：按服务端同一套规则在本地重排，不发请求。
    ///
    /// Mac 会把整个结果集拉进内存（``loadAllPages(maxPages:)``），这时点列头再从第一页
    /// 重拉就是白拉——两千条每页五百是四个请求，外加解码（代码审查）。顺序和服务端
    /// 逐条一致，见 ``ServerListingOrder``；所以之后刷新，行不会跳。
    ///
    /// 返回 `false` 表示条件不满足（还有没拉的页、正在请求、上次翻页失败），
    /// 调用方照旧走 ``setSort(_:)`` 去服务端排。只拉了几页的 iOS 永远走那条路。
    @discardableResult
    public func reorderLocally(_ newSort: ListingSort) -> Bool {
        guard !hasMore, !isLoading, !isLoadingMore, !loadMoreFailed else { return false }
        guard newSort != sort else { return true }
        // 之后的刷新 / 翻页都按新排序去问服务端，和眼前的顺序接得上。
        sort = newSort
        listings = ServerListingOrder.sorted(listings, by: newSort)
        return true
    }

    /// 换排序。重置分页从第一页重拉——结果集没拉全时**不能**只把已加载的重排，
    /// 那正是 iOS 当年那个 bug。全量在手时先试 ``reorderLocally(_:)``。
    public func setSort(_ newSort: ListingSort) async {
        guard newSort != sort else { return }
        await refresh(sort: newSort)
    }

    public func refresh(sort newSort: ListingSort? = nil) async {
        await fetch(city: currentCity, status: currentStatus, query: currentQuery,
                    sources: currentSources.isEmpty ? nil : currentSources,
                    cities: currentCities.isEmpty ? nil : currentCities,
                    types: currentTypes.isEmpty ? nil : currentTypes,
                    contract: currentContract, energy: currentEnergy,
                    sort: newSort)
    }

    /// 登出时清空所有用户相关状态，防止下个登入用户看到上个用户的数据。
    public func clear() {
        listings = []
        seenIDs = []
        loadMoreFailed = false
        total = 0
        isLoading = false
        isLoadingMore = false
        errorMessage = nil
        lastError = nil
        isFiltered = false
        lastUpdated = nil
        currentCity = nil
        currentStatus = nil
        currentQuery = nil
        currentSources = []
        currentCities = []
        currentTypes = []
        currentContract = nil
        currentEnergy = nil
        // 自增 generation —— 任何残留的 in-flight fetch 回来时都会被识别为过期丢弃。
        fetchGeneration &+= 1
    }
}
