import XCTest
@testable import FlatRadarCore

/// ``NotificationItem`` 的类型分类。
///
/// 这一组守的是一个**实测抓到的线上分类错误**：`classifyKind` 里
/// `blob.contains("→")` 原本排在"新房源"分支**前面**，而 `notifier.py` 拼的
/// 新房源 body 是
///
/// ```python
/// body = f"{listing.status} · {price}/mo · → {move_in}"
/// ```
///
/// ——**里面那个 `→` 是入住日**，不是状态迁移。于是每一条 `new_listing` 都被
/// 判成 `.status`。Mac 通知屏的筛选条把它暴露了出来：17 条通知里
/// `Status 17 / New 0`，而流里肉眼可见好几条 "New listing"。iOS 的筛选标签
/// 用的是同一个分类器，同样中招。
///
/// 规则定死为：**先认 `type`，正文启发式只作最后的兜底。**
final class NotificationKindTests: XCTestCase {

    private func kind(type: String, title: String = "[H2S] Blaak 555",
                      body: String) -> NotificationItem.Kind {
        NotificationItem.classifyKind(type: type, title: title, body: body)
    }

    /// 回归用例本体。
    func test_新房源不因为入住日的箭头被判成状态变化() {
        XCTAssertEqual(kind(type: "new_listing",
                            body: "Available to book · €407/mo · → 2026-10-01"), .book)
    }

    func test_抽签的新房源细分成lottery() {
        XCTAssertEqual(kind(type: "new_listing",
                            body: "Available in lottery · €452/mo · → 2026-10-01"), .lottery)
    }

    func test_状态变化仍然是status() {
        XCTAssertEqual(kind(type: "status_change",
                            body: "Reserved → Available to book · €1245/mo"), .status)
    }

    func test_booking按新房源算() {
        XCTAssertEqual(kind(type: "booking", body: "Booked · €900/mo"), .book)
    }

    func test_服务端异常类仍然是alert() {
        XCTAssertEqual(kind(type: "error", body: "Scraper failed"), .alert)
        XCTAssertEqual(kind(type: "scrape_failed", body: "403 from Xior"), .alert)
    }

    /// `channel_disabled`（通知渠道被停用）现在归 `.system`——它不含
    /// error/block/alert/fail 任一关键字。**这是既有行为，这条只是把它钉住**，
    /// 不是说它一定对：从产品上看"你的邮件通知已停用"更像该进 `.alert`。
    /// 真要改是另一件事（会动到 iOS 的筛选标签），不顺手夹带。
    func test_渠道停用目前归system_这是既有行为() {
        XCTAssertEqual(kind(type: "channel_disabled", body: "Email bounced"), .system)
    }

    func test_测试推送仍然是test() {
        XCTAssertEqual(kind(type: "test", body: "推送链路自检"), .test)
    }

    /// `type` 认不出时才轮到正文猜——这条守住兜底那一支没被一起删掉。
    func test_未知type时才靠正文里的箭头猜() {
        XCTAssertEqual(kind(type: "something_new", body: "Reserved → Book"), .status)
        XCTAssertEqual(kind(type: "something_new", body: "Total in DB: 831"), .system)
    }

    func test_心跳和公告是system() {
        XCTAssertEqual(kind(type: "heartbeat", body: "Total in DB: 831"), .system)
        XCTAssertEqual(kind(type: "announcement", body: "Scheduled maintenance"), .system)
    }
}
