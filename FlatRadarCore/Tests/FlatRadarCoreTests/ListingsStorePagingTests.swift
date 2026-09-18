import XCTest
@testable import FlatRadarCore

/// 「翻页途中刷新」那一类 bug。
///
/// 这类问题全是**两个请求谁先回来**：翻页请求在飞，这时刷新 / 换排序，新第一页
/// 先回来，旧那页后回来。真网络上排不出这个顺序，所以把 `ListingsStore.loadPage`
/// 换成一个能把请求扣住、由测试决定放行顺序的闸门。
///
/// 原先的问题（代码审查 P2，已复现）：旧那页回来时代号不对，提前 `return`，
/// 跳过了 `isLoadingMore = false`。锁永远挂着，之后的翻页全被挡回去，列表停在
/// 第一页、没有任何报错。
@MainActor
final class ListingsStorePagingTests: XCTestCase {

    // MARK: - 闸门

    /// 扣住每一个请求，按测试指定的顺序、指定的结果放行。
    @MainActor final class Gate {
        private var held: [(request: ListingsStore.PageRequest,
                            continuation: CheckedContinuation<ListingsResponse, Error>)] = []
        private(set) var requests: [ListingsStore.PageRequest] = []

        func load(_ request: ListingsStore.PageRequest) async throws -> ListingsResponse {
            requests.append(request)
            return try await withCheckedThrowingContinuation { held.append((request, $0)) }
        }

        /// 等到一共出现过 `n` 个请求。等不到就是被什么东西挡住了——那正是要抓的。
        func waitForRequests(_ n: Int, file: StaticString = #filePath, line: UInt = #line) async {
            for _ in 0..<500 where held.count + released < n || requests.count < n {
                await Task.yield()
            }
            XCTAssertGreaterThanOrEqual(requests.count, n,
                                        "等不到第 \(n) 个请求——翻页被挡住了", file: file, line: line)
        }

        private var released = 0

        /// 把还扣着的全放掉。收尾用——一个永远不放行的请求会让等它的任务永远挂着，
        /// 整个测试进程跟着卡死（写这组测试时真卡死过一次）。
        func releaseAll() {
            while let h = held.popLast() {
                released += 1
                h.continuation.resume(throwing: CancellationError())
            }
        }

        func release(offset: Int, _ result: Result<ListingsResponse, Error>) {
            guard let i = held.firstIndex(where: { $0.request.offset == offset }) else {
                return XCTFail("没有扣着 offset=\(offset) 的请求")
            }
            released += 1
            held.remove(at: i).continuation.resume(with: result)
        }
    }

    private func page(_ ids: [String], total: Int, offset: Int = 0) -> ListingsResponse {
        let items = ids.map {
            #"{"id":"\#($0)","name":"\#($0)","status":"Available to book","url":"","city":"Eindhoven"}"#
        }.joined(separator: ",")
        let json = #"{"items":[\#(items)],"total":\#(total),"limit":2,"offset":\#(offset)}"#
        return try! JSONDecoder().decode(ListingsResponse.self, from: Data(json.utf8))
    }

    /// 一个已经加载了第一页（a, b；共 6 条）的 store。
    private func loadedStore() async -> (ListingsStore, Gate) {
        let gate = Gate()
        let store = ListingsStore(pageSize: 2)
        store.loadPage = gate.load
        let first = Task { await store.fetch() }
        await gate.waitForRequests(1)
        gate.release(offset: 0, .success(page(["a", "b"], total: 6)))
        await first.value
        return (store, gate)
    }

    /// 翻页请求在飞 → 刷新 → 新第一页先回来 → 旧那页才回来。
    private func refreshWhilePaging(_ store: ListingsStore, _ gate: Gate,
                                    staleResult: Result<ListingsResponse, Error>) async {
        let more = Task { await store.loadMore() }
        await gate.waitForRequests(2)
        XCTAssertTrue(store.isLoadingMore)

        let refresh = Task { await store.refresh() }
        await gate.waitForRequests(3)
        gate.release(offset: 0, .success(page(["c", "d"], total: 6)))
        await refresh.value

        gate.release(offset: 2, staleResult)
        await more.value
    }

    // MARK: - 用例

    /// 就是审查里复现的那一条。
    func test_翻页途中刷新之后还能接着翻页() async {
        let (store, gate) = await loadedStore()
        await refreshWhilePaging(store, gate,
                                 staleResult: .success(page(["x", "y"], total: 6, offset: 2)))

        XCTAssertEqual(store.listings.map(\.id), ["c", "d"], "旧结果集的那页不能拼进新结果集")
        XCTAssertFalse(store.isLoadingMore, "锁不能挂着——原先就挂在这儿")

        // 关键：还能接着翻。原先这一步直接被 `!isLoadingMore` 挡回去，一个请求都不发。
        let next = Task { await store.loadMore() }
        await gate.waitForRequests(4)
        XCTAssertEqual(gate.requests.last?.offset, 2)
        gate.release(offset: 2, .success(page(["e", "f"], total: 6, offset: 2)))
        await next.value
        XCTAssertEqual(store.listings.map(\.id), ["c", "d", "e", "f"])
    }

    func test_过期的那页失败了也不能把新结果集标成失败() async {
        let (store, gate) = await loadedStore()
        await refreshWhilePaging(store, gate,
                                 staleResult: .failure(APIError.network(URLError(.timedOut))))

        XCTAssertFalse(store.loadMoreFailed,
                       "失败的是旧结果集的请求，新结果集的「加载失败 · 重试」不该冒出来")
        XCTAssertFalse(store.isLoadingMore)
    }

    /// Mac 表格用 `loadAllPages()` 一口气翻到底。翻到一半换排序，原先它会看到"这轮没多
    /// 出行"就退出，退出前把**新**结果集标成失败。
    func test_一口气翻到底时被刷新打断_不把新结果集标成失败() async {
        let (store, gate) = await loadedStore()
        let all = Task { await store.loadAllPages() }
        await gate.waitForRequests(2)

        let refresh = Task { await store.refresh() }
        await gate.waitForRequests(3)
        gate.release(offset: 0, .success(page(["c", "d"], total: 6)))
        await refresh.value

        gate.release(offset: 2, .success(page(["x", "y"], total: 6, offset: 2)))
        await all.value

        XCTAssertFalse(store.loadMoreFailed)
        XCTAssertEqual(store.listings.map(\.id), ["c", "d"])
    }

    /// 第一页还没回来时，`listings.count` 还是旧结果集的条数。拿它当 offset 去请求
    /// 新结果集，拿回来的是新排序里错位的一页。
    func test_第一页没回来之前不翻页() async {
        let (store, gate) = await loadedStore()
        let refresh = Task { await store.refresh() }
        await gate.waitForRequests(2)
        XCTAssertTrue(store.isLoading)

        // 放进任务里、不直接 await：要是它真发了请求，那个请求没人放行，
        // 直接 await 就会永远等下去。
        let more = Task { await store.loadMore() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(gate.requests.count, 2, "刷新还没回来，不该发翻页请求")

        gate.release(offset: 0, .success(page(["c", "d"], total: 6)))
        await refresh.value
        gate.releaseAll()
        await more.value
    }
}
