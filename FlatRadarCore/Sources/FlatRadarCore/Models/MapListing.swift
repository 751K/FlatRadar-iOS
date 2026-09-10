import CoreLocation
import Foundation

/// 地图视图中的单个房源；后端 `/api/v1/map` `listings[]` 数组的元素。
///
/// 与 ``Listing`` 的区别
/// --------------------
/// MapListing 是地图专用 DTO：含 ``lat`` / ``lng`` 坐标，不含完整 feature 列表。
/// 点击 pin → 弹卡 → 点详情按钮时，再走 ``ListingRoute.byId`` 让 ListingDetailView
/// 自己 ``getListing(id:)`` 拉全字段。
///
/// `nonisolated`：纯 DTO，没有任何可变状态，而且要跟着 ``MapClustering`` 一起
/// 进 `Task.detached` 做后台聚类。默认主 actor 隔离会把 ``displayCoordinate``
/// 这类派生属性也推断成 @MainActor，后台任务里读它就成了跨 actor 访问。
public nonisolated struct MapListing: Decodable, Identifiable, Hashable, Sendable {
    /// 契约里 `required` 的五个——缺任何一个都该报错，见 ``init(from:)``。
    public let id: String
    public let name: String
    public let status: String

    /// 以下全部**可缺省**。契约（`docs/openapi.json` 的 `MapListing`）只把
    /// `id / name / status / lat / lng` 列进 `required`，其余键后端可以不发；
    /// `available_from` / `city` / `address` 连类型都是 `["string", "null"]`，
    /// 即使发了也可能是 `null`。而 `url` / `neighborhood` / `building` / `area`
    /// 在契约的 `properties` 里**根本没有**，只靠 `additionalProperties: true`
    /// 存在——它们是「后端愿意就发」的字段，不是承诺。
    ///
    /// 合成的 `Decodable` 会把每个非可选属性都当必填。少一个键就
    /// `DecodingError.keyNotFound` → `MapResponse` 整个数组解不出来 →
    /// ``MapStore/fetch()`` 抛错 → 地图**一条都不显示**。一个从未承诺过的
    /// 字段，能让整张地图空掉。
    ///
    /// 所以这里用 `decodeIfPresent ?? ""` 而不是改成可选：调用方
    /// （`MapView` 的弹卡、``MapStore/passes(_:)`` 的价格/面积筛选）本来就在
    /// 用 `.isEmpty` 判空，空串正好落进它们已有的「没有这个值」分支。
    public let source: String?
    public let priceRaw: String
    public let availableFrom: String
    public let url: String
    public let city: String
    public let neighborhood: String
    public let building: String
    public let area: String
    let address: String

    /// 坐标**保持必填**：没有坐标的房源本来就不该出现在 `/map` 的
    /// `listings[]` 里，契约也把它们列进了 `required`。真的没坐标时，
    /// 后端走的是 ``MapLocateResult`` 的 `no_coords` 那一支——那是一条
    /// 说得出原因的路径，比在这里默默塞个 (0, 0) 把房源钉到几内亚湾好。
    let lat: Double
    let lng: Double

    /// 画图钉用的坐标，以及这个地址上一共有几套。
    ///
    /// 一栋楼的每个单元共用同一个街道地址，geocode 出来是**完全相同**的坐标。
    /// 网格聚类对重合点在任何 cell 大小下都归同一格，点击展开又会被
    /// ``ListingCluster.boundingRegion`` 的 minSpan 兜成固定视野——于是同址的
    /// 那几套**在任何缩放下都碰不到**。服务端已经把它们摆成一圈
    /// （`app/services/listing_service.spread_stacked_coords`），这里只负责取值。
    ///
    /// 可选是为了兼容还没更新的服务端：缺字段时退回真实坐标，而不是丢掉这个点。
    let displayLat: Double?
    let displayLng: Double?
    let stackN: Int?

    public enum CodingKeys: String, CodingKey {
        case id, name, status, source, url, city, neighborhood, building, area, address, lat, lng
        case priceRaw = "price_raw"
        case availableFrom = "available_from"
        case displayLat = "display_lat"
        case displayLng = "display_lng"
        case stackN = "stack_n"
    }

    /// 手写而不用合成：合成版把非可选属性一律当必填，而契约只承诺五个键。
    /// 逐字段对照见上面属性的注释。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // 契约 required——缺了就该响，这几个键没有合理的默认值。
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(String.self, forKey: .status)
        lat = try c.decode(Double.self, forKey: .lat)
        lng = try c.decode(Double.self, forKey: .lng)

        // 契约 optional / 压根没声明——缺失和显式 null 都退到空串。
        // `decodeIfPresent` 两种情况都返回 nil，正好覆盖 `["string", "null"]`。
        source = try c.decodeIfPresent(String.self, forKey: .source)
        priceRaw = try c.decodeIfPresent(String.self, forKey: .priceRaw) ?? ""
        availableFrom = try c.decodeIfPresent(String.self, forKey: .availableFrom) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        neighborhood = try c.decodeIfPresent(String.self, forKey: .neighborhood) ?? ""
        building = try c.decodeIfPresent(String.self, forKey: .building) ?? ""
        area = try c.decodeIfPresent(String.self, forKey: .area) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""

        displayLat = try c.decodeIfPresent(Double.self, forKey: .displayLat)
        displayLng = try c.decodeIfPresent(Double.self, forKey: .displayLng)
        stackN = try c.decodeIfPresent(Int.self, forKey: .stackN)
    }

    /// 真实坐标。用于「这套房到底在哪」——比如日后接入导航。
    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// 画在地图上的坐标。同址散开后是**近似值**，``stackCount`` > 1 时
    /// 界面必须说明这一点——不说的话用户会以为图钉就是门牌号。
    public var displayCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: displayLat ?? lat,
            longitude: displayLng ?? lng)
    }

    /// 这个地址上一共几套。服务端没给时按 1 处理。
    public var stackCount: Int { max(1, stackN ?? 1) }

    /// 归一化后的状态档。判据见 ``ListingStatus``，与 Web 同一份。
    public var statusKind: ListingStatus { ListingStatus.from(status) }

    /// 见 ``Platform``——全 App 唯一一份映射。此前这里只认得 H2S 和 OD，
    /// 其余五个平台在地图弹卡上显示成大写的 source key。
    var sourceShortText: String { Platform.shortName(source ?? "holland2stay") }

    var sourceDisplayText: String { Platform.displayName(source ?? "holland2stay") }
}

/// `GET /api/v1/map` 响应包络。
nonisolated struct MapResponse: Decodable, Sendable {
    let listings: [MapListing]
    public let uncached: Int
}

/// 「按 id 找这套房的坐标」的结果，**面向界面**的形态。
///
/// 为什么不直接把 ``MapLocateResult`` 放出去
/// --------------------------------------
/// 那是个传输 DTO（`ok: Bool` + `reason: String?` + 可空的 listing），
/// Phase 0 定的边界是**传输 DTO 一律留在包内**。把它 public 出去，调用方就得自己
/// 处理「ok 为 true 但 listing 是 nil」这种本不该存在的组合。
///
/// 这个枚举把那三种情况收成三个互斥的 case，**没有非法状态**。
/// 三种要分开报，不能合成一个 nil：`notFound` 是「后端不认识这条」，
/// `noCoordinates` 是「认识但还没地理编码出来」——用户能做的事不一样。
public nonisolated enum MapLocation: Sendable {
    /// 找到了，带坐标。注意 `stackCount > 1` 时位置是近似的，界面必须说明。
    case located(MapListing)
    case notFound
    case noCoordinates
}

/// `GET /api/v1/map/locate` 的**传输**形态。包内可见，界面拿到的是 ``MapLocation``。
///
/// 三种「看不到」必须分开报——合并成一句「没找到」的话，「等管理员解析地址」
/// 「这个链接作废了」「改一下筛选就能看到」在界面上长得一模一样，而用户能做的
/// 事完全不同。
nonisolated struct MapLocateResult: Decodable, Sendable {
    let ok: Bool
    let reason: String?
    let listing: MapListing?

    nonisolated enum Reason: String {
        case notFound = "not_found"
        case noCoords = "no_coords"
    }

    var parsedReason: Reason? { reason.flatMap(Reason.init(rawValue:)) }
}
