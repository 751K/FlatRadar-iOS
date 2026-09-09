import Foundation

/// `GET /listings` 的 `sort` 键。**逐个对应后端 openapi 的 enum**，不多不少。
///
/// 为什么排序必须是服务端的
/// ----------------------
/// 客户端只拿得到已加载的那几页（iOS 每页 50，全量 800+）。在那上面排序得到的是
/// 「已加载结果里最便宜的」，而不是「全部房源里最便宜的」——两者几乎永远不同，
/// 而界面上看不出区别。2026-09-09 之前 iOS 就是这样：`ListingsView` 对
/// `store.listings` 调 `sorted(using:)`，用户点「价格从低到高」看到的是第一页
/// 那 50 条里的最低价。
///
/// 后端 1.23.0 起提供服务端排序，这个类型是它在客户端的镜像。
public nonisolated enum ListingSortKey: String, CaseIterable, Sendable {
    case price
    /// 平方米。后端存派生列——原始值是 `feature_map` 里的 `"87.28 m²"` 文本。
    case area
    /// 能效等级的**秩**。升序 = 最好在前（A+++ 先于 F）。
    case energy
    case firstSeen = "first_seen"
    case lastSeen = "last_seen"
    case availableFrom = "available_from"
    case city
    /// 业务序，不是字典序：available to book < in lottery < reserved <
    /// occupied/rented/not available < other。字典序会把 "Available in lottery"
    /// 排在 "Available to book" 前面，毫无意义。
    case status
    case source
}

/// 一次排序请求：键 + 方向。
///
/// 线格式是后端约定的前导 `-` 表示降序（`price` 升 / `-price` 降）。
/// 逗号形式（`city,-price`）后端保留给将来的多键排序，**当前会被 400 拒绝**，
/// 所以这里不提供构造多键的入口。
public nonisolated struct ListingSort: Equatable, Sendable {

    public var key: ListingSortKey
    public var ascending: Bool

    public init(key: ListingSortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// 发给后端的值。
    public var wireValue: String { ascending ? key.rawValue : "-\(key.rawValue)" }

    /// 不传 `sort` 时后端的行为。**这是契约的一部分**，不是实现细节——
    /// 后端 1.23.0 起把它写进了 openapi 的 `default`。
    public static let newestFirst = ListingSort(key: .firstSeen, ascending: false)

    /// 后端对每一次查询都追加 `, id ASC` 兜底，所以 offset 翻页是稳定的。
    /// 在此之前规格里**没有承诺任何顺序**，翻页理论上会重复或漏项。
    /// 客户端仍然按 id 去重（见 ``ListingsStore``）——两道保险，代价是一个 Set。
    public static let hasStableTiebreak = true
}
