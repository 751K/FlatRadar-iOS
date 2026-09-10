import SwiftUI
import MapKit
import FlatRadarCore

/// 地图上的一个**楼盘**——同一个地址上的若干套房源。
///
/// 为什么地图的单位是楼盘不是房源
/// ----------------------------
/// 设计稿的地图标记显示的是 `from €407 · 5`，不是一枚一枚的针。原因在数据里：
/// `MapListing.stackCount > 1` 表示这些房源共用一个地址，后端把它们撒在一个
/// 小圈上（`display_lat` 的文档原话："treat as approximate"）。
///
/// 一栋楼里 12 套单元画 12 枚针，等于用 12 个**假坐标**冒充 12 个位置。
/// 聚成一个标记、把数量写在上面，说的才是实话：这个位置有 12 套。
struct MapBuilding: Identifiable, Hashable {

    let id: String
    let name: String
    let city: String
    let coordinate: CLLocationCoordinate2D
    /// 这栋楼里的房源，按「最值得看」排过序（可订 > 抽签 > 已占 …）。
    let units: [MapListing]

    var count: Int { units.count }

    /// 标记上显示哪一套的状态：取业务优先级最高的那个。
    ///
    /// 一栋楼里有 1 套可订、11 套已租，标记该是绿的——那 1 套才是用户要找的。
    /// 取"最多的那个状态"会把它埋掉。
    var leadStatus: ListingStatus { units.first?.statusKind ?? .other }

    /// 楼里最低价。多套时标记显示 `from €407`。
    var lowestPrice: Double? { units.compactMap { PriceText.parse($0.priceRaw) }.min() }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    // MARK: - 聚合

    /// 把房源按**坐标**归拢成楼盘。
    ///
    /// 用坐标而不是 `building` 字段：那个字段来自 `feature_map`，各平台填法不一，
    /// 有的干脆是空的（Xior 的几条实测就和 city 同名）。坐标是后端地理编码出来的，
    /// 同一个地址必然同一个值。
    ///
    /// 精度取小数点后 5 位 ≈ 1.1 米——足够把同一栋楼归到一起，又不会把街对面
    /// 的另一栋并进来。
    static func group(_ listings: [MapListing]) -> [MapBuilding] {
        var buckets: [String: [MapListing]] = [:]
        for l in listings {
            let c = l.coordinate
            let key = String(format: "%.5f,%.5f", c.latitude, c.longitude)
            buckets[key, default: []].append(l)
        }
        return buckets.map { key, group in
            let sorted = group.sorted { $0.statusKind.priority < $1.statusKind.priority }
            let head = sorted[0]
            return MapBuilding(
                id: key,
                // 楼盘名优先用 `building`，空了退回第一套的名字——总得有个称呼。
                name: head.building.isEmpty ? head.name : head.building,
                city: head.city,
                coordinate: head.coordinate,
                units: sorted)
        }
        // 排序只为让 SwiftUI 的 ForEach 稳定，不影响显示。
        .sorted { $0.id < $1.id }
    }
}

/// 地图上按城市聚合的一团。缩得太远时用它代替一栋栋的楼盘。
struct MapCluster: Identifiable, Hashable {
    let id: String          // 城市名
    let coordinate: CLLocationCoordinate2D
    let buildings: [MapBuilding]
    var unitCount: Int { buildings.reduce(0) { $0 + $1.count } }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// 按城市归拢，位置取该城市所有楼盘的重心。
    static func group(_ buildings: [MapBuilding]) -> [MapCluster] {
        Dictionary(grouping: buildings, by: \.city).map { city, list in
            let lat = list.reduce(0) { $0 + $1.coordinate.latitude } / Double(list.count)
            let lon = list.reduce(0) { $0 + $1.coordinate.longitude } / Double(list.count)
            return MapCluster(id: city,
                              coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                              buildings: list)
        }
        .sorted { $0.id < $1.id }
    }
}
