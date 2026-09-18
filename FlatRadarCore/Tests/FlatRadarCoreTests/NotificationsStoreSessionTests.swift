import XCTest
@testable import FlatRadarCore

@MainActor
final class NotificationsStoreSessionTests: XCTestCase {
    @MainActor
    private final class Gate {
        var offsets: [Int] = []
        var reads: [[Int]?] = []
        private var pages: [Int: CheckedContinuation<NotificationsResponse, Error>] = [:]
        private var writes: [Int: CheckedContinuation<Void, Error>] = [:]

        func page(limit: Int, offset: Int) async throws -> NotificationsResponse {
            let index = offsets.count
            offsets.append(offset)
            return try await withCheckedThrowingContinuation { pages[index] = $0 }
        }

        func markRead(_ ids: [Int]?) async throws {
            let index = reads.count
            reads.append(ids)
            try await withCheckedThrowingContinuation { writes[index] = $0 }
        }

        func release(_ index: Int, _ result: Result<NotificationsResponse, Error>) {
            guard let continuation = pages.removeValue(forKey: index) else {
                return XCTFail("No pending page \(index)")
            }
            continuation.resume(with: result)
        }

        func completeRead(_ index: Int) {
            guard let continuation = writes.removeValue(forKey: index) else {
                return XCTFail("No pending read \(index)")
            }
            continuation.resume()
        }

        func cancelAll() {
            for continuation in pages.values { continuation.resume(throwing: CancellationError()) }
            for continuation in writes.values { continuation.resume(throwing: CancellationError()) }
            pages.removeAll()
            writes.removeAll()
        }
    }

    private func makeStore(_ gate: Gate) -> NotificationsStore {
        let store = NotificationsStore()
        store.loadPage = gate.page
        store.markReadRequest = gate.markRead
        store.updateBadge = { _ in }
        return store
    }

    private func response(_ ids: [Int], total: Int? = nil, unread: Int = 0) -> NotificationsResponse {
        let items: [[String: Any]] = ids.map {
            ["id": $0, "created_at": "2026-09-18T09:00:00Z", "type": "new_listing",
             "title": "Listing \($0)", "body": "Available", "read": 0]
        }
        let json: [String: Any] = ["items": items, "total": total ?? ids.count,
                                   "unread": unread, "limit": 50, "offset": 0]
        return try! JSONDecoder().decode(NotificationsResponse.self,
                                        from: JSONSerialization.data(withJSONObject: json))
    }

    private func waitUntil(_ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Expected async operation did not start", file: file, line: line)
    }

    func testOldFetchCannotPopulateNewSessionOrFinishItsLoadingState() async {
        let gate = Gate()
        defer { gate.cancelAll() }
        let store = makeStore(gate)
        let old = Task { await store.fetch() }
        await waitUntil { gate.offsets.count == 1 }
        store.clear()
        let current = Task { await store.fetch() }
        await waitUntil { gate.offsets.count == 2 }
        let revision = store.revision
        gate.release(0, .success(response([1], total: 10, unread: 10)))
        await old.value
        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertTrue(store.isLoading)
        XCTAssertEqual(store.total, 0)
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(store.revision, revision)
        gate.release(1, .success(response([2], unread: 1)))
        await current.value
        XCTAssertEqual(store.notifications.map(\.id), [2])
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.unreadCount, 1)
    }

    func testOldFetchFailureCannotSetErrorAfterClear() async {
        let gate = Gate()
        defer { gate.cancelAll() }
        let store = makeStore(gate)
        let task = Task { await store.fetch() }
        await waitUntil { gate.offsets.count == 1 }
        store.clear()
        gate.release(0, .failure(APIError.network(URLError(.timedOut))))
        await task.value
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.isLoading)
    }

    func testOldPaginationCannotAppendToNewSession() async {
        let gate = Gate()
        defer { gate.cancelAll() }
        let store = makeStore(gate)
        store.notifications = response([1]).items
        store.total = 2
        let old = Task { await store.loadMore() }
        await waitUntil { gate.offsets.count == 1 }
        store.clear()
        store.notifications = response([9]).items
        store.total = 2
        let current = Task { await store.loadMore() }
        await waitUntil { gate.offsets.count == 2 }
        gate.release(0, .success(response([2], total: 200)))
        await old.value
        XCTAssertEqual(store.notifications.map(\.id), [9])
        XCTAssertEqual(store.total, 2)
        XCTAssertTrue(store.isLoadingMore)
        gate.release(1, .success(response([10], total: 2)))
        await current.value
        XCTAssertEqual(store.notifications.map(\.id), [9, 10])
        XCTAssertFalse(store.isLoadingMore)
    }

    func testCancelledBackfillCannotWriteAfterClear() async {
        let gate = Gate()
        defer { gate.cancelAll() }
        let store = makeStore(gate)
        let fetch = Task { await store.fetch() }
        await waitUntil { gate.offsets.count == 1 }
        gate.release(0, .success(response([1], total: 3, unread: 3)))
        await fetch.value
        await waitUntil { gate.offsets.count == 2 }
        XCTAssertEqual(gate.offsets, [0, 1])
        store.clear()
        let revision = store.revision
        // This fake transport deliberately returns success despite task cancellation.
        gate.release(1, .success(response([2], total: 3, unread: 3)))
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertEqual(store.total, 0)
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(gate.offsets.count, 2)
    }

    func testOldMarkReadCannotChangeNewAccountsMatchingID() async {
        await checkStaleRead(markAll: false)
    }

    func testOldMarkAllReadCannotClearNewAccountsUnreadCount() async {
        await checkStaleRead(markAll: true)
    }

    private func checkStaleRead(markAll: Bool) async {
        let gate = Gate()
        defer { gate.cancelAll() }
        let store = makeStore(gate)
        store.notifications = response([1]).items
        store.unreadCount = 1
        let old = Task {
            if markAll { await store.markAllRead() }
            else { await store.markRead(ids: [1]) }
        }
        await waitUntil { gate.reads.count == 1 }
        store.clear()
        store.notifications = response([1, 2]).items
        store.unreadCount = 2
        let revision = store.revision
        gate.completeRead(0)
        await old.value
        XCTAssertEqual(store.unreadCount, 2)
        XCTAssertTrue(store.notifications.allSatisfy { !$0.isRead })
        XCTAssertEqual(store.revision, revision)
    }

    func testRefreshInvalidatesOldPageAndAllowsNewPagination() async {
        let gate = Gate()
        defer { gate.cancelAll() }
        let store = makeStore(gate)
        store.notifications = response([1]).items
        store.total = 3
        let old = Task { await store.loadMore() }
        await waitUntil { gate.offsets.count == 1 }
        let refresh = Task { await store.refresh() }
        await waitUntil { gate.offsets.count == 2 }
        await store.loadMore()
        XCTAssertEqual(gate.offsets.count, 2)
        gate.release(1, .success(response([9], total: 2)))
        await refresh.value
        gate.release(0, .success(response([2], total: 3)))
        await old.value
        XCTAssertEqual(store.notifications.map(\.id), [9])
        XCTAssertFalse(store.isLoadingMore)
        let page = Task { await store.loadMore() }
        await waitUntil { gate.offsets.count == 3 }
        gate.release(2, .success(response([10], total: 2)))
        await page.value
        XCTAssertEqual(store.notifications.map(\.id), [9, 10])
    }

    func testCancelledFetchDoesNotStartBackfill() async {
        let gate = Gate()
        defer { gate.cancelAll() }
        let store = makeStore(gate)
        let fetch = Task { await store.fetch() }
        await waitUntil { gate.offsets.count == 1 }
        fetch.cancel()
        gate.release(0, .success(response([1], total: 3, unread: 3)))
        await fetch.value
        for _ in 0..<100 { await Task.yield() }
        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(gate.offsets.count, 1)
    }

    func testCurrentMarkReadStillUpdatesUnreadCount() async {
        let gate = Gate()
        defer { gate.cancelAll() }
        let store = makeStore(gate)
        store.notifications = response([1, 2]).items
        store.unreadCount = 2
        let task = Task { await store.markRead(ids: [1]) }
        await waitUntil { gate.reads.count == 1 }
        gate.completeRead(0)
        await task.value
        XCTAssertTrue(store.notifications[0].isRead)
        XCTAssertFalse(store.notifications[1].isRead)
        XCTAssertEqual(store.unreadCount, 1)
    }

    func testCurrentUnreadBackfillStillLoadsRemainingPages() async {
        let gate = Gate()
        defer { gate.cancelAll() }
        let store = makeStore(gate)
        let fetch = Task { await store.fetch() }
        await waitUntil { gate.offsets.count == 1 }
        gate.release(0, .success(response([1], total: 3, unread: 3)))
        await fetch.value
        XCTAssertFalse(store.isLoading)
        await waitUntil { gate.offsets.count == 2 }
        gate.release(1, .success(response([2], total: 3, unread: 3)))
        await waitUntil { gate.offsets.count == 3 }
        gate.release(2, .success(response([3], total: 3, unread: 3)))
        await waitUntil { store.notifications.count == 3 && !store.isLoadingMore }
        XCTAssertEqual(store.notifications.map(\.id), [1, 2, 3])
        XCTAssertEqual(gate.offsets, [0, 1, 2])
        XCTAssertEqual(store.unreadCount, 3)
    }
}
