import XCTest
@testable import FlatRadarCore

// MARK: - 全量在手时，换排序不请求

/// 每次改变排序都会重新请求全部分页（代码审查）。
///
/// Mac 已经把房源全量拉进内存，点列头却仍从第一页开始、再顺序拉完所有页。
@MainActor
final class ListingsStoreLocalSortTests: XCTestCase {

    private func listing(_ id: String, price: String) -> Listing {
        let json = #"{"id":"\#(id)","name":"\#(id)","status":"Available to book","url":"","city":"Eindhoven","price_raw":"\#(price)"}"#
        return try! JSONDecoder().decode(Listing.self, from: Data(json.utf8))
    }

    private func store(total: Int? = nil, requests: @escaping (ListingsStore.PageRequest) -> Void) -> ListingsStore {
        let s = ListingsStore(pageSize: 500)
        s.listings = [listing("c", price: "€900"), listing("a", price: "€700"), listing("b", price: "")]
        s.total = total ?? s.listings.count
        s.loadPage = { request in
            requests(request)
            throw CancellationError()
        }
        return s
    }

    func test_全量在手_换排序本地重排_不发请求() {
        var sent = 0
        let s = store { _ in sent += 1 }
        let sort = ListingSort(key: .price, ascending: true)

        XCTAssertTrue(s.reorderLocally(sort))
        XCTAssertEqual(sent, 0, "全量已经在手，不该再请求")
        XCTAssertEqual(s.listings.map(\.id), ["a", "c", "b"], "价格升序，读不出价格的沉底")
        XCTAssertEqual(s.sort, sort, "之后的刷新要按新排序去问服务端")
    }

    func test_本地重排之后刷新_带的是新排序() async {
        var sorts: [ListingSort?] = []
        let s = store { sorts.append($0.sort) }
        let sort = ListingSort(key: .city, ascending: false)
        s.reorderLocally(sort)
        await s.refresh()
        XCTAssertEqual(sorts, [sort])
    }

    func test_还有没拉的页_不在本地排() {
        let s = store(total: 10) { _ in }
        XCTAssertFalse(s.reorderLocally(ListingSort(key: .price, ascending: true)),
                       "只拉了一部分时本地排出来的是「已加载里最便宜的」，正是 iOS 当年那个 bug")
        XCTAssertEqual(s.sort, .newestFirst)
    }

    func test_正在请求时_不在本地排() {
        let s = store { _ in }
        s.isLoading = true
        XCTAssertFalse(s.reorderLocally(ListingSort(key: .price, ascending: true)))
    }
}

// MARK: - 通知：标已读只翻一位、SSE 在主线程外解码
//
// 取数的"晚到响应作废"由 `NotificationsStoreSessionTests` 守（codex/localmac 那边的实现和
// 测试）；第二个窗口不再重复取数由 Mac 的 `SharedLoadTests` 守（合并在 `AppFeed` 那一层）。

final class NotificationItemCostTests: XCTestCase {

    nonisolated static func item(_ id: Int, read: Bool = false) -> String {
        #"{"id":\#(id),"created_at":"2026-09-10T09:38:00","type":"status_change","title":"[H2S] Unit \#(id)","body":"Reserved → Available to book · €1.200/mo","read":\#(read ? 1 : 0),"listing_id":"L\#(id)","url":""}"#
    }

    func test_标已读只翻已读位_其余原样() throws {
        let unread = try JSONDecoder().decode(NotificationItem.self, from: Data(Self.item(7).utf8))
        let read = unread.markedRead()
        XCTAssertTrue(read.isRead)
        XCTAssertEqual(read.id, unread.id)
        XCTAssertEqual(read.kind, unread.kind)
        XCTAssertEqual(read.listingTitleHint, unread.listingTitleHint)
        XCTAssertEqual(read.parsedDate, unread.parsedDate)
        XCTAssertEqual(read, try JSONDecoder().decode(NotificationItem.self,
                                                      from: Data(Self.item(7, read: true).utf8)),
                       "和服务端直接给一条已读的，应当是同一个值")
    }

    func test_SSE_一批解码_坏数据以错误返回而不是断流() async throws {
        let payload = "[" + [1, 2].map { Self.item($0) }.joined(separator: ",") + "]"
        let decoded = try await NotificationsStore.decodeBatch(payload).get()
        XCTAssertEqual(decoded.map(\.id), [1, 2])
        if case .success = await NotificationsStore.decodeBatch("{not json") {
            XCTFail("坏数据应当以 .failure 返回，由 handleSSEData 记进 streamError")
        }
    }
}

// MARK: - 「全部已读」的开销

/// 原先 `markedRead()` 走完整的 init：分类、标题正则、日期解析全部重跑。
/// 这里把"重建"和"复制翻一位"各跑两千条，打印出来写进报告；断言只要求快一个数量级。
@MainActor
final class MarkReadCostTests: XCTestCase {

    private func items(_ n: Int, createdAt: String) -> [NotificationItem] {
        (0..<n).map { i in
            let json = #"{"id":\#(i),"created_at":"\#(createdAt)","type":"status_change","title":"[H2S] Unit \#(i)","body":"Reserved → Available to book · €1.200/mo","read":0,"listing_id":"L\#(i)","url":""}"#
            return try! JSONDecoder().decode(NotificationItem.self, from: Data(json.utf8))
        }
    }

    private func ms(_ body: () -> Void) -> Double {
        let t = Date()
        body()
        return Date().timeIntervalSince(t) * 1000
    }

    func test_两千条全部已读_复制比重建快一个数量级() {
        var lines: [String] = []
        for (label, createdAt) in [("ISO 带时区", "2026-09-10T09:38:00+00:00"),
                                   ("无时区", "2026-09-10 09:38:00")] {
            let all = items(2000, createdAt: createdAt)
            let rebuild = ms {
                _ = all.map { NotificationItem(id: $0.id, createdAt: $0.createdAt, type: $0.type,
                                               title: $0.title, body: $0.body, url: $0.url,
                                               listingID: $0.listingID, read: 1) }
            }
            let copy = ms { _ = all.map { $0.markedRead() } }
            lines.append(String(format: "%@：重建 %.1fms → 复制 %.2fms", label, rebuild, copy))
            XCTAssertLessThan(copy * 10, rebuild)
        }
        print("MARKREAD\n" + lines.joined(separator: "\n"))
    }
}
