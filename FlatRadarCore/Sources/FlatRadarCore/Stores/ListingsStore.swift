import Foundation

@MainActor
@Observable
public final class ListingsStore {

    /// 隐式 init 随 `public` 一起变成 internal，宿主 app 构造不了。
    /// 这些 store 的属性全有默认值，空实现与迁移前的隐式构造等价。
    public init() {}
    public var listings: [Listing] = []
    public var total = 0
    public var isLoading = false
    public var isLoadingMore = false
    public var errorMessage: String?
    public var lastError: APIError?
    public var isFiltered = false
    /// 最近一次成功 fetch 的本地时间戳 — 用于 ListingsView 顶部 "updated 2m ago" 心跳条。
    public var lastUpdated: Date?

    private let client = APIClient.shared
    private let pageSize = 50

    // Current filter state
    private var currentCity: String?
    private var currentStatus: String?
    private var currentQuery: String?
    private var currentSources: [String] = []
    private var currentCities: [String] = []
    private var currentTypes: [String] = []
    private var currentContract: String?
    private var currentEnergy: String?

    /// 当前排序。发给后端，不在本地排——本地只能排已加载的那几页，
    /// 得到的是「已加载结果里最便宜的」而不是「全部里最便宜的」。
    /// 见 ``ListingSort``。
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

    var hasMore: Bool { listings.count < total }

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
        do {
            let resp = try await client.getListings(
                city: city, status: status, query: query,
                limit: pageSize, offset: 0,
                sources: sources, cities: cities, types: types,
                contract: contract, energy: energy, sort: self.sort)
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

    public func loadMore() async {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        let myGen = fetchGeneration   // load-more 不自增 generation；用 fetch 的代号
        do {
            let resp = try await client.getListings(
                city: currentCity, status: currentStatus, query: currentQuery,
                limit: pageSize, offset: listings.count,
                sources: currentSources.isEmpty ? nil : currentSources,
                cities: currentCities.isEmpty ? nil : currentCities,
                types: currentTypes.isEmpty ? nil : currentTypes,
                contract: currentContract, energy: currentEnergy, sort: sort)
            // load-more 期间 filter 改了 → 这批分页响应属于旧 filter，丢掉
            guard myGen == fetchGeneration else { return }
            let fresh = resp.items.filter { seenIDs.insert($0.id).inserted }
            listings.append(contentsOf: fresh)
            total = resp.total
            loadMoreFailed = false
        } catch {
            if !error.isCancellation { loadMoreFailed = true }
        }
        isLoadingMore = false
    }

    /// 换排序。重置分页从第一页重拉——**不能**只把已加载的重排，
    /// 那正是这次要修掉的 bug。
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
