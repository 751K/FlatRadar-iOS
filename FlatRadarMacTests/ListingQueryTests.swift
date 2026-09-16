import XCTest
@testable import FlatRadarMac
@testable import FlatRadarCore

/// 列表屏本地筛选的逐条对账。
///
/// 这套逻辑**没有后端可以对**：822 条全在内存里，筛错了不会有任何报错，
/// 只会安静地少给几条房源——而少给的那几条正是用户要找的。
final class ListingQueryTests: XCTestCase {

    private func make(id: String = "1",
                      city: String = "Amsterdam",
                      source: String = "holland2stay",
                      status: String = "Available to book",
                      priceRaw: String? = "€1000",
                      priceValue: Double? = 1000,
                      area: String? = "50 m²",
                      type: String? = "Studio",
                      energy: String? = "A",
                      availableFrom: String? = "2026-10-01") throws -> Listing {
        var features: [String: String] = [:]
        if let area { features["area"] = area }
        if let type { features["type"] = type }
        if let energy { features["energy_label"] = energy }
        var obj: [String: Any] = ["id": id, "name": "N", "status": status,
                                  "city": city, "source": source, "url": "",
                                  "feature_map": features, "features": []]
        if let priceRaw { obj["price_raw"] = priceRaw }
        if let priceValue { obj["price_value"] = priceValue }
        if let availableFrom { obj["available_from"] = availableFrom }
        return try JSONDecoder().decode(
            Listing.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    // MARK: - 匹配

    func test_空条件谁都不筛() throws {
        XCTAssertTrue(ListingQuery().isEmpty)
        XCTAssertTrue(ListingQuery().matches(try make()))
    }

    /// 同一个维度里勾多项是**或**。
    func test_维度内是或() throws {
        var q = ListingQuery()
        q.cities = ["Amsterdam", "Eindhoven"]
        XCTAssertTrue(q.matches(try make(city: "Amsterdam")))
        XCTAssertTrue(q.matches(try make(city: "Eindhoven")))
        XCTAssertFalse(q.matches(try make(city: "Rotterdam")))
    }

    /// 跨维度是**且**。
    func test_维度之间是且() throws {
        var q = ListingQuery()
        q.cities = ["Amsterdam"]
        q.types = ["Studio"]
        XCTAssertTrue(q.matches(try make(city: "Amsterdam", type: "Studio")))
        XCTAssertFalse(q.matches(try make(city: "Amsterdam", type: "Loft")))
        XCTAssertFalse(q.matches(try make(city: "Eindhoven", type: "Studio")))
    }

    /// 状态走 `ListingStatus.from` 归一，不是字符串相等——后端同一个状态有好几种写法。
    func test_状态按归一后的枚举比() throws {
        var q = ListingQuery()
        q.statuses = [.book]
        XCTAssertTrue(q.matches(try make(status: "Available to book")))
        XCTAssertTrue(q.matches(try make(status: "available_to_book")))
        XCTAssertFalse(q.matches(try make(status: "Occupied")))
    }

    // MARK: - 读不出来的那些

    /// **读不出价格 ≠ 超预算。** 留着，和地图那边一个口径。
    /// 反过来做的话，"On request" 的房源会在设了预算之后集体消失，
    /// 而用户完全不会知道自己漏看了什么。
    func test_读不出价格的不被预算筛掉() throws {
        var q = ListingQuery()
        q.maxRent = 900
        XCTAssertFalse(q.matches(try make(priceRaw: "€1000", priceValue: 1000)))
        XCTAssertTrue(q.matches(try make(priceRaw: "€800", priceValue: 800)))
        XCTAssertTrue(q.matches(try make(priceRaw: "On request", priceValue: nil)))
        XCTAssertTrue(q.matches(try make(priceRaw: nil, priceValue: nil)))
    }

    /// 面积同理。顺带验证欧陆写法能读出来——`22,56` 不能当成 2256。
    func test_面积能读出来且读不出的留着() throws {
        var q = ListingQuery()
        q.minArea = 30
        XCTAssertTrue(q.matches(try make(area: "50 m²")))
        XCTAssertFalse(q.matches(try make(area: "22,56 m²")))
        XCTAssertTrue(q.matches(try make(area: "33,78 m²")))
        XCTAssertTrue(q.matches(try make(area: nil)))
    }

    /// 后端拿 2050-01-01 当"未知"占位，这种不算有日期。
    func test_有入住日期走哨兵判据() throws {
        var q = ListingQuery()
        q.datedOnly = true
        XCTAssertTrue(q.matches(try make(availableFrom: "2026-10-01")))
        XCTAssertFalse(q.matches(try make(availableFrom: "2050-01-01")))
        XCTAssertFalse(q.matches(try make(availableFrom: nil)))
    }

    // MARK: - 候选项和计数

    /// 计数是**全局**的：候选项来自全量，不随其它维度的勾选变。
    func test_候选项按条数排且计数是全局的() throws {
        let listings = [
            try make(id: "1", city: "Amsterdam"),
            try make(id: "2", city: "Amsterdam"),
            try make(id: "3", city: "Eindhoven"),
        ]
        let options = ListingQuery.options(listings, value: \.city)
        XCTAssertEqual(options.map(\.value), ["Amsterdam", "Eindhoven"])
        XCTAssertEqual(options.map(\.count), [2, 1])
    }

    /// 空值不进候选项——列一个点了什么也不会发生的空选项，比不列糟。
    func test_空值不进候选项() throws {
        let listings = [try make(id: "1", type: "Studio"), try make(id: "2", type: nil)]
        XCTAssertEqual(ListingQuery.options(listings, value: { $0.typeText }).map(\.value),
                       ["Studio"])
    }

    func test_状态计数覆盖五档() throws {
        let listings = [
            try make(id: "1", status: "Available to book"),
            try make(id: "2", status: "Available to book"),
            try make(id: "3", status: "Occupied"),
        ]
        let counts = ListingQuery.statusCounts(listings)
        XCTAssertEqual(counts[.book], 2)
        XCTAssertEqual(counts[.occupied], 1)
        XCTAssertNil(counts[.lottery])
    }
}
