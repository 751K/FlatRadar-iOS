import XCTest
@testable import FlatRadarMac
@testable import FlatRadarCore

/// 通知流的 body 解析和分组。
///
/// 为什么这一组值得写
/// ----------------
/// 这一屏唯一在**依赖字符串格式**的地方就是 body：后端 `notifier.py` 拼的是
///
/// ```python
/// type="status_change"  body = f"{old_status} → {new_status} · {price}/mo"
/// type="new_listing"    body = f"{listing.status} · {price}/mo · → {move_in}"
/// ```
///
/// 两种 body 里**都有 `→`**，含义却完全不同。靠找箭头来猜的话，新房源会被读成
/// 一次状态迁移，右边的胶囊就会显示成「Available to book → 2026-10-01」——
/// 把一个日期当成状态。这组用例把「按 type 分派」这件事钉死。
final class AlertFeedTests: XCTestCase {

    @MainActor
    private func item(_ type: String, _ body: String,
                      title: String = "[H2S] Blaak 555-19.01",
                      id: Int = 1, read: Int = 0,
                      createdAt: String = "2026-09-10T09:38:00") -> NotificationItem {
        let json = """
        {"id":\(id),"created_at":"\(createdAt)","type":"\(type)",
         "title":"\(title)","body":"\(body)","read":\(read),"listing_id":"L1","url":"https://x"}
        """
        return try! JSONDecoder().decode(NotificationItem.self, from: Data(json.utf8))
    }

    // MARK: - body 解析

    @MainActor
    func test_状态变化拆出旧状态新状态和价格() {
        let r = AlertFeed.parse(item("status_change", "Reserved → Available to book · €1.245/mo"))
        XCTAssertEqual(r.from, "Reserved")
        XCTAssertEqual(r.to, "Available to book")
        XCTAssertEqual(r.price, "€1245")
    }

    /// 这一条守的就是上面说的坑：新房源的 body 里那个 `→` 是**入住日**，
    /// 不是状态迁移。解析成迁移的话胶囊会把一个日期显示成状态。
    @MainActor
    func test_新房源里的箭头是入住日不是状态迁移() {
        let r = AlertFeed.parse(item("new_listing", "Available to book · €407/mo · → 2026-10-01"))
        XCTAssertNil(r.from, "新上架没有「旧状态」")
        XCTAssertEqual(r.to, "Available to book")
        XCTAssertEqual(r.price, "€407")
    }

    @MainActor
    func test_没有房源状态的类型不硬拆() {
        for type in ["heartbeat", "error", "announcement"] {
            let r = AlertFeed.parse(item(type, "Total in DB: 831"))
            XCTAssertNil(r.from, type)
            XCTAssertNil(r.to, type)
            XCTAssertNil(r.price, type)
        }
    }

    /// 价格走 ``PriceText``，和列表、日历同一份口径——欧洲写法的小数点
    /// 不能被当成千位分隔符（`€1.067,50` 是 1067.5，不是 106750）。
    @MainActor
    func test_价格归一到和列表同一个口径() {
        XCTAssertEqual(AlertFeed.price(in: "Reserved → Book · € 1.067,50/mo"), "€1068")
        XCTAssertEqual(AlertFeed.price(in: "Book · €407/mo · → 2026-10-01"), "€407")
        XCTAssertNil(AlertFeed.price(in: "Total in DB: 831"))
    }

    @MainActor
    func test_同状态重复通知说still不说X到X() {
        let n = item("status_change", "Available in lottery → Available in lottery · €452/mo")
        let row = AlertFeed.row(n, platforms: Platform.knownKeys)
        XCTAssertEqual(row.summary, "Still Available in lottery")
    }

    // MARK: - 平台反查

    @MainActor
    func test_从标题前缀反查平台_认不出就是nil() {
        let known = Platform.knownKeys
        XCTAssertEqual(AlertFeed.source(from: "[H2S] Blaak 555", known: known), "holland2stay")
        XCTAssertEqual(AlertFeed.source(from: "[XR] Iets", known: known), "xior")
        // 认不出**不套默认平台**：显示成 Holland2Stay 会让人以为数据是那边来的。
        XCTAssertNil(AlertFeed.source(from: "[ZZZ] Iets", known: known))
        XCTAssertNil(AlertFeed.source(from: "No prefix at all", known: known))
    }

    // MARK: - 分组

    @MainActor
    func test_按天分组且组内最新在前() {
        let rows = [
            AlertFeed.row(item("status_change", "A → B · €1/mo", id: 1,
                               createdAt: "2026-09-10T08:00:00"), platforms: []),
            AlertFeed.row(item("status_change", "A → B · €1/mo", id: 2,
                               createdAt: "2026-09-10T09:30:00"), platforms: []),
            AlertFeed.row(item("status_change", "A → B · €1/mo", id: 3,
                               createdAt: "2026-09-09T22:00:00"), platforms: [])
        ]
        let days = AlertFeed.days(rows, now: dateAt("2026-09-10T12:00:00"))
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].label, "Today")
        XCTAssertEqual(days[0].rows.map(\.id), [2, 1], "组内该是最新在前")
        XCTAssertEqual(days[1].label, "Yesterday")
    }

    @MainActor
    func test_未读数按天算() {
        let rows = [
            AlertFeed.row(item("status_change", "A → B · €1/mo", id: 1, read: 0,
                               createdAt: "2026-09-10T08:00:00"), platforms: []),
            AlertFeed.row(item("status_change", "A → B · €1/mo", id: 2, read: 1,
                               createdAt: "2026-09-10T09:00:00"), platforms: [])
        ]
        let days = AlertFeed.days(rows, now: dateAt("2026-09-10T12:00:00"))
        XCTAssertEqual(days[0].unread, 1)
    }

    // MARK: - 24 小时分桶

    @MainActor
    func test_分桶是十二个且桶边界对齐到偶数小时() {
        // 09:38 所在的当前桶是 08:00–10:00，所以最后一桶的起点是 08:00，
        // 整条轴覆盖前一天 10:00 到今天 10:00。
        let rows = [
            AlertFeed.row(item("status_change", "A → B · €1/mo", id: 1,
                               createdAt: "2026-09-10T09:38:00"), platforms: []),
            AlertFeed.row(item("status_change", "A → B · €1/mo", id: 2,
                               createdAt: "2026-09-10T08:05:00"), platforms: []),
            AlertFeed.row(item("status_change", "A → B · €1/mo", id: 3,
                               createdAt: "2026-09-09T11:00:00"), platforms: [])
        ]
        let buckets = AlertFeed.buckets(rows, now: dateAt("2026-09-10T09:38:00"))
        XCTAssertEqual(buckets.count, 12)
        XCTAssertEqual(buckets.last, 2, "09:38 和 08:05 都落在最后那个 08–10 的桶里")
        XCTAssertEqual(buckets.reduce(0, +), 3)
    }

    /// 超过 24 小时的不进桶——柱状图的标签写的是「Last 24 hours」。
    @MainActor
    func test_超过窗口的条目不进桶() {
        let rows = [AlertFeed.row(item("status_change", "A → B · €1/mo",
                                       createdAt: "2026-09-01T09:00:00"), platforms: [])]
        XCTAssertEqual(AlertFeed.buckets(rows, now: dateAt("2026-09-10T09:38:00")).reduce(0, +), 0)
    }

    @MainActor
    func test_今天和最近七天两个数() {
        let rows = [
            AlertFeed.row(item("status_change", "A → B · €1/mo", id: 1,
                               createdAt: "2026-09-10T08:00:00"), platforms: []),
            AlertFeed.row(item("status_change", "A → B · €1/mo", id: 2,
                               createdAt: "2026-09-06T08:00:00"), platforms: []),
            AlertFeed.row(item("status_change", "A → B · €1/mo", id: 3,
                               createdAt: "2026-08-01T08:00:00"), platforms: [])
        ]
        let t = AlertFeed.totals(rows, now: dateAt("2026-09-10T12:00:00"))
        XCTAssertEqual(t.today, 1)
        XCTAssertEqual(t.week, 2, "8 月那条在 7 天之外")
    }

    // MARK: - 工具

    @MainActor
    private func dateAt(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = ServerTime.calendar
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: iso)!
    }
}
