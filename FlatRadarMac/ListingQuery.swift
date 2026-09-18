import Foundation
import FlatRadarCore

/// 列表屏的**本地**筛选条件。
///
/// 为什么全部本地算
/// --------------
/// Mac 端 `ListingsStore(pageSize: 500)` + `loadAllPages()` 已经把全量拉进内存
/// （实测 822 条）。本地筛是即时的、没有网络往返，也不会出现"筛的只是已加载的
/// 那一页"。
///
/// 注意这和「排序必须走服务端」（`1b365c9`）**不矛盾**：排序决定哪些条目会被分页
/// 带回来，本地排只能排到手上这一页；而筛选在**全量在手**时本地算反而更准，
/// 还省掉每勾一下就发一次请求。
///
/// 一个维度内是"或"，维度之间是"且"。
///
/// `nonisolated`：工程开着 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不写的话
/// 这个纯值类型会被钉到主 actor 上，`FlatRadarMacTests` 里就调不动（测试 target
/// 没开默认隔离）。它不碰任何状态，本来也不该有 actor。
nonisolated struct ListingQuery: Equatable, Sendable {

    var cities: Set<String> = []
    var sources: Set<String> = []
    var types: Set<String> = []
    var energy: Set<String> = []
    var statuses: Set<ListingStatus> = []
    var maxRent: Double?
    var minArea: Double?

    /// 只看有明确入住日期的。后端拿 `2050-01-01` 这种远端日期当"未知"占位，
    /// 判据见 ``Listing/hasRealAvailableDate``。
    var datedOnly = false

    var isEmpty: Bool {
        cities.isEmpty && sources.isEmpty && types.isEmpty && energy.isEmpty
            && statuses.isEmpty && maxRent == nil && minArea == nil && !datedOnly
    }

    func matches(_ l: Listing) -> Bool {
        if !cities.isEmpty, !cities.contains(l.city) { return false }
        if !sources.isEmpty, !sources.contains(l.source ?? "") { return false }
        if !types.isEmpty, !types.contains(l.typeText ?? "") { return false }
        if !energy.isEmpty, !energy.contains(l.energyText ?? "") { return false }
        if !statuses.isEmpty, !statuses.contains(ListingStatus.from(l.status)) { return false }

        // **读不出价格 ≠ 超预算**，面积同理：读不出就留着，不当成不匹配。
        // 和地图那边一个口径（`MapStore.passes`），界面上也有一句话说明。
        if let maxRent, let v = l.priceValue ?? PriceText.parse(l.priceRaw), v > maxRent {
            return false
        }
        if let minArea, let v = AreaText.value(l.areaText), v < minArea {
            return false
        }
        if datedOnly, !l.hasRealAvailableDate { return false }
        return true
    }
}

// MARK: - 候选项

/// 某个维度的一个候选项：值 + 显示名 + 全量里有多少条。
nonisolated struct FilterOption: Identifiable, Equatable {
    let value: String
    let label: String
    let count: Int
    var id: String { value }
}

nonisolated extension ListingQuery {

    /// 从**全量**房源里取某个维度的候选项。
    ///
    /// 计数是**全局**的，不随其它维度的勾选变。设计稿上四组计数各自正好加到总数，
    /// 说明取的就是全局计数；而且交叉计数虽然看着聪明，代价是每勾一下所有数字都
    /// 跟着跳，反而没法拿来判断"这一项值不值得勾"。
    ///
    /// 排序按条数多到少，同数按名字——列表屏的候选项里"哪个城市房源多"本身
    /// 就是信息。
    static func options(_ listings: [Listing],
                        value: (Listing) -> String?,
                        label: (String) -> String = { $0 }) -> [FilterOption] {
        var counts: [String: Int] = [:]
        for l in listings {
            guard let v = value(l), !v.isEmpty else { continue }
            counts[v, default: 0] += 1
        }
        return counts
            .map { FilterOption(value: $0.key, label: label($0.key), count: $0.value) }
            .sorted { $0.count == $1.count ? $0.label < $1.label : $0.count > $1.count }
    }

    /// 五档状态各有多少条。状态的顺序是固定的（见 ``ListingStatus``），
    /// 不按条数排——那几档的先后本身是有含义的。
    static func statusCounts(_ listings: [Listing]) -> [ListingStatus: Int] {
        var out: [ListingStatus: Int] = [:]
        for l in listings { out[ListingStatus.from(l.status), default: 0] += 1 }
        return out
    }
}
