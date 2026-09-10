import Foundation

/// `GET /api/v1/calendar` ``listings[]`` 数组的元素。
///
/// 与 ``Listing`` / ``MapListing`` 的区别
/// ------------------------------------
/// CalendarListing 是日历专用 DTO：必含非空 ``availableFrom``（后端 SQL 已
/// `WHERE available_from IS NOT NULL AND != ''`），其它字段稀疏。点击进
/// 详情时走 ``ListingRoute.byId`` 让 ``ListingDetailView`` 自己 fetch 全字段。
public nonisolated struct CalendarListing: Decodable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let status: String
    public let source: String?

    /// ``availableFrom`` **保持必填**：它在契约的 `required` 里，而且是这个
    /// DTO 存在的理由——后端 SQL 已经 `WHERE available_from IS NOT NULL AND != ''`，
    /// 日历没有它就没法分组。契约里它也是纯 `"string"`，不允许 `null`。
    public let availableFrom: String   // ISO yyyy-MM-dd

    /// 以下都**可缺省**：`docs/openapi.json` 的 `CalendarListing.required` 只有
    /// `id / name / status / available_from`。`price_raw` 是 optional，
    /// `url` / `city` / `building` 更是 `["string", "null"]`——发了也可能是 null。
    /// 合成的 `Decodable` 把它们当必填，少一个键整个 `CalendarResponse.listings`
    /// 就解不出来，日历会整页空掉。同 ``MapListing`` 那处。
    public let priceRaw: String
    public let url: String
    public let city: String
    public let building: String

    public enum CodingKeys: String, CodingKey {
        case id, name, status, source, url, city, building
        case priceRaw = "price_raw"
        case availableFrom = "available_from"
    }

    /// 手写而不用合成，理由见上面各属性的注释。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(String.self, forKey: .status)
        availableFrom = try c.decode(String.self, forKey: .availableFrom)

        source = try c.decodeIfPresent(String.self, forKey: .source)
        priceRaw = try c.decodeIfPresent(String.self, forKey: .priceRaw) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? ""
        building = try c.decodeIfPresent(String.self, forKey: .building) ?? ""
    }

    /// 解析 ``availableFrom`` 为 ``Date``（按服务器 Amsterdam 日期）；解析失败返回 nil。
    public var date: Date? { Self.dateFormatter.date(from: availableFrom) }

    /// 用于按"日"分组的 key（YYYY-MM-DD），保证同一天的房源会聚合在一起。
    public var dayKey: String { String(availableFrom.prefix(10)) }

    var sourceShortText: String { Platform.shortName(source ?? "holland2stay") }

    var sourceDisplayText: String { Platform.displayName(source ?? "holland2stay") }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

nonisolated struct CalendarResponse: Decodable, Sendable {
    let listings: [CalendarListing]
}
