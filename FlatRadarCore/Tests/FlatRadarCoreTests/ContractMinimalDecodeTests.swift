import XCTest
@testable import FlatRadarCore

/// 「后端只发契约承诺的那几个键」时，客户端还解不解得出来。
///
/// 为什么要有这一组
/// ----------------
/// 每个 DTO 的非可选属性都是合成 `Decodable` 眼里的**必填字段**。而
/// `docs/openapi.json` 的 `required` 数组通常短得多——中间那些「客户端要求、
/// 契约没承诺」的字段就是定时炸弹：后端某天不发其中一个（或者按契约允许的
/// 那样发 `null`），`DecodingError` 会把**整个数组**打掉，不是少一条房源，
/// 而是地图 / 日历 / 列表整页空白。
///
/// 实测撞到的那次：`MapListing` 少一个 `address` 键就 `keyNotFound`，而
/// `address` 在契约里从头到尾都是可选的。
///
/// 每个用例的 JSON 都是**照契约 `required` 一字不多**地抄下来的。往下加字段
/// 会让用例失去意义——它守的就是「只有这些键」这件事。
final class ContractMinimalDecodeTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - MapListing —— required: id, name, status, lat, lng

    func test_MapListing_只含契约必填字段也能解出来() throws {
        let l = try decode(MapListing.self, """
        {"id":"1","name":"Unit 3","status":"Available to book","lat":52.09,"lng":5.12}
        """)

        XCTAssertEqual(l.id, "1")
        XCTAssertEqual(l.lat, 52.09)
        XCTAssertEqual(l.lng, 5.12)
        // 契约没承诺的那些退到空串，而不是让整条记录消失。
        XCTAssertEqual(l.priceRaw, "")
        XCTAssertEqual(l.availableFrom, "")
        XCTAssertEqual(l.url, "")
        XCTAssertEqual(l.city, "")
        XCTAssertEqual(l.neighborhood, "")
        XCTAssertEqual(l.building, "")
        XCTAssertEqual(l.area, "")
        XCTAssertEqual(l.address, "")
        XCTAssertNil(l.source)
        // 没有 display_* 时退回真实坐标——这条老行为不能被这次改动带歪。
        XCTAssertEqual(l.displayCoordinate.latitude, 52.09)
        XCTAssertEqual(l.stackCount, 1)
    }

    /// 契约里 `available_from` / `city` / `address` 的类型是 `["string", "null"]`。
    /// 「键在、值是 null」和「键不在」是两件事，都得扛住。
    func test_MapListing_契约允许的_null_值不会打掉解码() throws {
        let l = try decode(MapListing.self, """
        {"id":"1","name":"Unit 3","status":"Available to book","lat":52.0,"lng":5.0,
         "available_from":null,"city":null,"address":null}
        """)
        XCTAssertEqual(l.availableFrom, "")
        XCTAssertEqual(l.city, "")
        XCTAssertEqual(l.address, "")
    }

    /// 坐标是**故意**保持必填的。没有坐标的房源不该出现在 `/map` 的
    /// `listings[]` 里；真没有时后端走 ``MapLocateResult`` 的 `no_coords`。
    /// 在这里默默兜底成 0 会把房源钉到几内亚湾，比报错更难查。
    func test_MapListing_缺坐标仍然报错() {
        XCTAssertThrowsError(try decode(MapListing.self, """
        {"id":"1","name":"Unit 3","status":"Available to book","lng":5.0}
        """)) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("缺 lat 应该是 keyNotFound，实际是 \(error)")
            }
        }
        XCTAssertThrowsError(try decode(MapListing.self, """
        {"id":"1","name":"Unit 3","status":"Available to book","lat":52.0}
        """))
    }

    /// 单条能解不够——地图的失败形态是「一条坏的拖垮整个数组」。
    func test_MapResponse_数组里全是最小记录也能解出来() throws {
        let r = try decode(MapResponse.self, """
        {"listings":[
          {"id":"1","name":"A","status":"Available to book","lat":52.0,"lng":5.0},
          {"id":"2","name":"B","status":"Rented","lat":51.9,"lng":4.5}
        ],"uncached":0}
        """)
        XCTAssertEqual(r.listings.count, 2)
    }

    /// `MapLocateResult` 只承诺 `ok`；`no_coords` 那一支不带 listing。
    func test_MapLocateResult_只含_ok() throws {
        let r = try decode(MapLocateResult.self, #"{"ok":false,"reason":"no_coords"}"#)
        XCTAssertEqual(r.parsedReason, .noCoords)
        XCTAssertNil(r.listing)
    }

    // MARK: - Listing —— required: id, name, status, city（city 本身可为 null）

    func test_Listing_只含契约必填字段也能解出来() throws {
        let l = try decode(Listing.self, """
        {"id":"1","name":"Unit 3","status":"Available to book","city":"Utrecht"}
        """)
        XCTAssertEqual(l.city, "Utrecht")
        // `url` 连 required 都不在，契约类型还是 `["string", "null"]`。
        XCTAssertEqual(l.url, "")
        XCTAssertNil(l.priceRaw)
        XCTAssertEqual(l.features, [])
    }

    func test_Listing_city_为_null_不会打掉解码() throws {
        let l = try decode(Listing.self, """
        {"id":"1","name":"Unit 3","status":"Available to book","city":null,"url":null}
        """)
        XCTAssertEqual(l.city, "")
        XCTAssertEqual(l.url, "")
    }

    func test_ListingsResponse_数组里全是最小记录也能解出来() throws {
        let r = try decode(ListingsResponse.self, """
        {"items":[{"id":"1","name":"A","status":"Rented","city":null}],
         "total":1,"limit":50,"offset":0,"filtered":false}
        """)
        XCTAssertEqual(r.items.count, 1)
    }

    // MARK: - CalendarListing —— required: id, name, status, available_from

    func test_CalendarListing_只含契约必填字段也能解出来() throws {
        let l = try decode(CalendarListing.self, """
        {"id":"1","name":"Unit 3","status":"Available to book","available_from":"2026-10-01"}
        """)
        XCTAssertEqual(l.dayKey, "2026-10-01")
        XCTAssertEqual(l.priceRaw, "")
        XCTAssertEqual(l.url, "")
        XCTAssertEqual(l.city, "")
        XCTAssertEqual(l.building, "")
    }

    /// `available_from` 是**故意**保持必填的：它是这个 DTO 存在的理由，
    /// 契约里也是纯 `"string"`（不允许 null）。
    func test_CalendarListing_缺_available_from_仍然报错() {
        XCTAssertThrowsError(try decode(CalendarListing.self, """
        {"id":"1","name":"Unit 3","status":"Available to book"}
        """))
    }

    func test_CalendarResponse_数组里全是最小记录也能解出来() throws {
        let r = try decode(CalendarResponse.self, """
        {"listings":[{"id":"1","name":"A","status":"Rented","available_from":"2026-10-01"}]}
        """)
        XCTAssertEqual(r.listings.count, 1)
    }

    // MARK: - Notification —— required: id, created_at, type, title, body, read

    func test_NotificationItem_只含契约必填字段也能解出来() throws {
        let n = try decode(NotificationItem.self, """
        {"id":7,"created_at":"2026-09-01T10:00:00","type":"new_listing",
         "title":"New listing","body":"Something","read":0}
        """)
        XCTAssertEqual(n.id, 7)
        XCTAssertEqual(n.url, "")
        XCTAssertEqual(n.listingID, "")
        XCTAssertFalse(n.isRead)
    }

    func test_NotificationItem_listing_id_为_null_不会打掉解码() throws {
        let n = try decode(NotificationItem.self, """
        {"id":7,"created_at":"2026-09-01T10:00:00","type":"info",
         "title":"T","body":"B","read":1,"listing_id":null,"user_id":null}
        """)
        XCTAssertEqual(n.listingID, "")
        XCTAssertTrue(n.isRead)
    }

    // MARK: - MonitorStatus

    /// 契约的 `MonitorStatus`（`GET /admin/monitor/status`）→ ``AdminMonitorStatus``。
    /// required 只有 `running` / `pid`。
    func test_AdminMonitorStatus_只含契约必填字段也能解出来() throws {
        let s = try decode(AdminMonitorStatus.self, #"{"running":true,"pid":null}"#)
        XCTAssertTrue(s.running)
        XCTAssertNil(s.pid)
        XCTAssertEqual(s.lastScrape, "")
        XCTAssertEqual(s.lastCount, "")
    }

    /// 契约里 `last_count` 是 `["string", "integer", "null"]`——三种都合法。
    /// 之前只认字符串，后端发个整数就 `typeMismatch`，整张监控卡片报错。
    func test_AdminMonitorStatus_last_count_可以是整数也可以是字符串() throws {
        let asInt = try decode(AdminMonitorStatus.self, """
        {"running":true,"pid":42,"last_scrape":"2026-09-01T10:00:00","last_count":137}
        """)
        XCTAssertEqual(asInt.lastCount, "137")

        let asString = try decode(AdminMonitorStatus.self, """
        {"running":false,"pid":null,"last_count":"137"}
        """)
        XCTAssertEqual(asString.lastCount, "137")
    }

    /// 契约的 `PublicSummary`（`GET /stats/public/summary`）→ ``MonitorStatus``。
    /// 它本来就写得很宽容，这条守住别在重构里被收紧。
    func test_MonitorStatus_last_scrape_为_null_不会打掉解码() throws {
        let s = try decode(MonitorStatus.self, """
        {"total":10,"new_24h":1,"new_7d":3,"changes_24h":0,"last_scrape":null}
        """)
        XCTAssertEqual(s.total, 10)
        XCTAssertEqual(s.lastScrape, "")
    }

    // MARK: - MeSummary —— last_scrape 在 required 里，但类型允许 null

    func test_MeSummary_last_scrape_为_null_不会打掉解码() throws {
        let s = try decode(MeSummary.self, """
        {"role":"user","total_in_db":100,"new_24h_total":2,"matched_total":5,
         "matched_available":1,"last_scrape":null,"filter_active":true}
        """)
        XCTAssertEqual(s.lastScrape, "")
        XCTAssertEqual(s.matchedTotal, 5)
        XCTAssertTrue(s.filterActive)
    }

    // MARK: - ChartResponse —— required: key, days, data

    func test_ChartData_只含契约必填字段也能解出来() throws {
        let c = try decode(ChartData.self, #"{"key":"city_dist","days":30,"data":[]}"#)
        XCTAssertEqual(c.key, "city_dist")
        XCTAssertEqual(c.days, 30)
        XCTAssertTrue(c.data.isEmpty)
    }

    // MARK: - Device —— required: id, device_token_hint, env, platform, disabled

    func test_DeviceInfo_只含契约必填字段也能解出来() throws {
        let d = try decode(DeviceInfo.self, """
        {"id":3,"device_token_hint":"ab…yz","env":"production",
         "platform":"ios","disabled":false}
        """)
        XCTAssertEqual(d.id, 3)
        XCTAssertFalse(d.disabled)
        XCTAssertEqual(d.model, "")
        XCTAssertEqual(d.disabledReason, "")
        // 时间戳缺失是 nil 不是 ""——"没有时间"和"空字符串时间"不是一回事。
        XCTAssertNil(d.createdAt)
        XCTAssertNil(d.lastSeen)
    }

    /// 契约里 `created_at` / `last_seen` 是 `["string", "null"]`。
    func test_DeviceInfo_时间戳为_null_不会打掉解码() throws {
        let d = try decode(DeviceInfo.self, """
        {"id":3,"device_token_hint":"ab…yz","env":"sandbox","platform":"ios",
         "disabled":true,"created_at":null,"last_seen":null,"model":"iPhone17,1"}
        """)
        XCTAssertNil(d.createdAt)
        XCTAssertEqual(d.model, "iPhone17,1")
    }

    /// 单台能解不够——设备页的失败形态是「一台坏的拖垮整张列表」。
    func test_DeviceListResponse_数组里全是最小记录也能解出来() throws {
        let r = try decode(DeviceListResponse.self, """
        {"items":[
          {"id":1,"device_token_hint":"a…z","env":"production","platform":"ios","disabled":false},
          {"id":2,"device_token_hint":"b…y","env":"sandbox","platform":"android","disabled":true}
        ]}
        """)
        XCTAssertEqual(r.items.count, 2)
    }

    // MARK: - AdminUser —— 四个开关都不在 required 里

    func test_AdminUserSummary_只含契约必填字段也能解出来() throws {
        let u = try decode(AdminUserSummary.self, """
        {"id":"u1","name":"Alice","enabled":true,"notifications_enabled":false,
         "channel_count":0,"channels":[],"active_devices":2,"filter_summary":{}}
        """)
        XCTAssertEqual(u.id, "u1")
        XCTAssertEqual(u.activeDevices, 2)
        // 后端没说的开关一律读作关——界面据此不标徽章。
        XCTAssertFalse(u.appLoginEnabled)
        XCTAssertFalse(u.autoBookEnabled)
    }

    /// 契约里 `filter_summary` 只写了 `type: "object"`，一个属性都没声明。
    /// 空对象 `{}` 是完全合法的取值。
    func test_AdminFilterSummary_空对象也能解出来() throws {
        let f = try decode(AdminFilterSummary.self, "{}")
        XCTAssertFalse(f.filterActive)
        // filterActive 为 false 时界面不显示这行，compactDescription 只是兜底。
        XCTAssertEqual(f.compactDescription, "—")
    }

    func test_AdminUsersResponse_数组里全是最小记录也能解出来() throws {
        let r = try decode(AdminUsersResponse.self, """
        {"items":[{"id":"u1","name":"A","enabled":true,"notifications_enabled":true,
                   "channel_count":1,"channels":["email"],"active_devices":0,
                   "filter_summary":{}}],"total":1}
        """)
        XCTAssertEqual(r.items.count, 1)
        XCTAssertEqual(r.items[0].filterSummary.compactDescription, "—")
    }

    // MARK: - FilterOptions —— 契约里没有 required，整个对象可以是 {}

    func test_FilterOptions_空对象也能解出来() throws {
        let o = try decode(FilterOptions.self, "{}")
        XCTAssertTrue(o.cities.isEmpty)
        XCTAssertTrue(o.sources.isEmpty)
        XCTAssertTrue(o.neighborhoods.isEmpty)
        // 老 backend 没有 dim_sources：空字典意味着「不知道」，界面据此不作标注。
        XCTAssertTrue(o.dimSources.isEmpty)
    }
}
