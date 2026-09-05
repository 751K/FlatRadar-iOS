import XCTest
@testable import FlatRadar

final class ListingTests: XCTestCase {

    // MARK: - Decoding

    func test_decode_basic_fields() throws {
        let json = """
        {
            "id": "abc123", "name": "Test Listing", "status": "Available to book",
            "city": "Eindhoven", "source": "holland2stay", "url": "https://example.com",
            "price_raw": "€707/mo", "price_value": 707.0,
            "features": [], "feature_map": {}
        }
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertEqual(listing.id, "abc123")
        XCTAssertEqual(listing.name, "Test Listing")
        XCTAssertEqual(listing.status, "Available to book")
        XCTAssertEqual(listing.city, "Eindhoven")
        XCTAssertEqual(listing.priceRaw, "€707/mo")
        XCTAssertEqual(listing.priceValue, 707.0)
    }

    func test_decode_with_featureMap() throws {
        let json = """
        {"id": "x", "name": "x", "status": "x", "city": "x", "features": [], "feature_map": {"area": "26 m²", "energy_label": "A++", "floor": "5"}, "url": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertEqual(listing.featureMap["area"], "26 m²")
        XCTAssertEqual(listing.featureMap["energy_label"], "A++")
        XCTAssertEqual(listing.featureMap["floor"], "5")
    }

    func test_decode_defaults_for_optional_fields() throws {
        let json = """
        {"id": "1", "name": "N", "status": "S", "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertEqual(listing.source, nil)
        XCTAssertEqual(listing.priceRaw, nil)
        XCTAssertEqual(listing.features, [])
        XCTAssertEqual(listing.featureMap, [:])
        XCTAssertEqual(listing.url, "")
        XCTAssertEqual(listing.city, "")
    }

    // MARK: - 展示用文案
    //
    // 这一组用例长期编译不过：断言里的 displayPrice / displayArea /
    // displayAvailableFrom 在 Listing 上根本不存在（真实名字是 priceRaw /
    // areaText / availableShortText），而**整个测试 target 编译不过 = 一条
    // iOS 测试都没在跑**。改名那次没人发现，正是因为它早就是红的。

    func test_priceRaw_is_kept_verbatim() throws {
        let json = """
        {"id": "1", "name": "N", "status": "S", "price_raw": "€1200/mo", "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertEqual(listing.priceRaw, "€1200/mo")
    }

    func test_priceValue_is_decoded() throws {
        let json = """
        {"id": "1", "name": "N", "status": "S", "price_value": 850.0, "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertEqual(listing.priceValue, 850.0)
    }

    func test_areaText_from_featureMap() throws {
        let json = """
        {"id": "1", "name": "N", "status": "S", "feature_map": {"area": "45 m²"}, "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertEqual(listing.areaText, "45 m²")
    }

    func test_areaText_missing_is_nil() throws {
        let json = """
        {"id": "1", "name": "N", "status": "S", "feature_map": {}, "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertNil(listing.areaText)
    }

    func test_availableShortText_shortens_date() throws {
        let json = """
        {"id": "1", "name": "N", "status": "S", "available_from": "2026-06-15 00:00:00", "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertNotNil(listing.availableShortText)
        XCTAssertTrue(listing.availableShortText?.contains("15") == true)
    }

    func test_availableShortText_missing_is_nil() throws {
        let json = """
        {"id": "1", "name": "N", "status": "S", "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertNil(listing.availableShortText)
    }

    func test_sentinel_available_from_is_not_a_real_date() throws {
        // 与 ServerTime.isSentinelDate / 后端 is_sentinel_available_from 同判据。
        let json = """
        {"id": "1", "name": "N", "status": "S", "available_from": "2050-01-01", "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertFalse(listing.hasRealAvailableDate)
        XCTAssertNil(listing.availableShortText)
    }

    func test_sentinel_judgement_follows_the_year_not_one_exact_day() throws {
        // 哨兵换成 2099 时，写死 hasPrefix("2050") 的实现会漏。
        let json = """
        {"id": "1", "name": "N", "status": "S", "available_from": "2099-03-04", "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertFalse(listing.hasRealAvailableDate)
    }

    // MARK: - statusKind

    func test_statusKind_book() throws {
        let json = """
        {"id": "1", "name": "N", "status": "Available to book", "features": [], "feature_map": {}, "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertEqual(listing.statusKind, .book)
    }

    func test_statusKind_lottery() throws {
        let json = """
        {"id": "1", "name": "N", "status": "Available in lottery", "features": [], "feature_map": {}, "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertEqual(listing.statusKind, .lottery)
    }

    func test_statusKind_reserved() throws {
        let json = """
        {"id": "1", "name": "N", "status": "Rented", "features": [], "feature_map": {}, "url": "", "city": ""}
        """
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        XCTAssertEqual(listing.statusKind, .reserved)
    }

    // MARK: - Hashable / Equatable

    /// Listing 自定义了 `init(from decoder:)`，因此**没有** memberwise init——
    /// 原用例直接 `Listing(id:name:...)` 构造，同样是编译不过的一条。
    private func makeListing(id: String, name: String, status: String) throws -> Listing {
        let json = """
        {"id": "\(id)", "name": "\(name)", "status": "\(status)",
         "features": [], "feature_map": {}, "url": "", "city": ""}
        """
        return try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
    }

    /// 同 id 但字段不同的两条**不相等**。
    ///
    /// 原用例叫 test_equality_by_id，断言的是「id 相同即相等」——而 Listing 用的是
    /// 编译器合成的 Hashable，比的是全部存储属性。那条断言从来没成立过，只是它
    /// 所在的文件从来没被编译，也就从来没跑过。
    ///
    /// 结构相等在这里是对的：SwiftUI 靠 == 决定要不要重画；若按 id 相等，房源
    /// 状态从 Available 变成 Reserved 时列表不会刷新。
    func test_equality_is_structural_not_by_id_alone() throws {
        let a = try makeListing(id: "x", name: "A", status: "S")
        let b = try makeListing(id: "x", name: "B", status: "T")
        XCTAssertNotEqual(a, b)
    }

    func test_identical_listings_are_equal() throws {
        let a = try makeListing(id: "x", name: "A", status: "S")
        let b = try makeListing(id: "x", name: "A", status: "S")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func test_id_still_identifies_for_swiftui() throws {
        // Identifiable 那一半仍然按 id——ForEach 靠它追踪行。
        let a = try makeListing(id: "x", name: "A", status: "S")
        let b = try makeListing(id: "x", name: "B", status: "T")
        XCTAssertEqual(a.id, b.id)
    }

    func test_different_ids_are_not_equal() throws {
        let a = try makeListing(id: "a", name: "A", status: "S")
        let b = try makeListing(id: "b", name: "A", status: "S")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - firstSeenDate 的 ISO8601 解析

    /// 带小数秒（后端最常发的形态）。
    func test_firstSeen_parses_iso_with_fractional_seconds() throws {
        let l = Self.listing(firstSeen: "2026-09-05T08:30:00.123Z")
        let t = try XCTUnwrap(l.firstSeenDate).timeIntervalSince1970
        XCTAssertEqual(t, 1_788_597_000.123, accuracy: 0.01)
    }

    /// **不带**小数秒。这条是补上的：原来只试带小数秒的那个解析器，不带的会
    /// 掉进 DateFormatter 兜底，而那批格式串没有一个能吃掉末尾的 `Z`，于是
    /// 整条返回 nil——`isNew` 恒为 false、`ageText` 恒为 nil，静默地不对。
    func test_firstSeen_parses_iso_without_fractional_seconds() throws {
        let l = Self.listing(firstSeen: "2026-09-05T08:30:00Z")
        let t = try XCTUnwrap(l.firstSeenDate).timeIntervalSince1970
        XCTAssertEqual(t, 1_788_597_000, accuracy: 0.01)
    }

    /// 带时区偏移的也要认（+02:00 = 阿姆斯特丹夏令时）。
    func test_firstSeen_parses_iso_with_offset() throws {
        let l = Self.listing(firstSeen: "2026-09-05T10:30:00+02:00")
        let t = try XCTUnwrap(l.firstSeenDate).timeIntervalSince1970
        XCTAssertEqual(t, 1_788_597_000, accuracy: 0.01)
    }

    /// 没有时区的裸时间戳仍然走 DateFormatter 兜底，按阿姆斯特丹时区读。
    /// 这条守的是「换成 ISO8601FormatStyle 之后把兜底那条路弄丢了」。
    func test_firstSeen_falls_back_for_zoneless_timestamp() throws {
        let l = Self.listing(firstSeen: "2026-09-05 10:30:00")
        XCTAssertNotNil(l.firstSeenDate)
    }

    func test_firstSeen_garbage_is_nil() throws {
        XCTAssertNil(Self.listing(firstSeen: "not a date").firstSeenDate)
        XCTAssertNil(Self.listing(firstSeen: "").firstSeenDate)
    }

    private static func listing(firstSeen: String) -> Listing {
        let json = """
        {"id":"x","name":"n","status":"Book","price_raw":"€1",
         "city":"Amsterdam","first_seen":"\(firstSeen)"}
        """.data(using: .utf8)!
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Listing.self, from: json)
    }

}
