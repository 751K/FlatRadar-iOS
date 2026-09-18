import XCTest
import FlatRadarCore
@testable import FlatRadarMac

/// 独立房源窗口跟着会话走（代码审查 P2）。
///
/// 原先窗口只按房源 id 加载、不看认证状态：退出后照旧显示详情；换号不清也不重载；
/// 系统恢复窗口时会话还没恢复完就发请求，失败了就停在错误上。
@MainActor
final class ListingWindowSessionTests: XCTestCase {

    // MARK: - 该不该取数

    func test_会话还在恢复时不取数_哪怕身份已经有了() {
        XCTAssertEqual(ListingWindow.gate(listing: "a", isRestoringSession: true, sessionIdentity: nil),
                       .waitingForSession)
        XCTAssertEqual(ListingWindow.gate(listing: "a", isRestoringSession: true, sessionIdentity: "user:k"),
                       .waitingForSession)
    }

    func test_没登录时不显示房源() {
        XCTAssertEqual(ListingWindow.gate(listing: "a", isRestoringSession: false, sessionIdentity: nil),
                       .signedOut)
    }

    func test_登录着就按房源加会话身份取() {
        XCTAssertEqual(ListingWindow.gate(listing: "a", isRestoringSession: false, sessionIdentity: "guest"),
                       .load(.init(id: "a", session: "guest")))
        XCTAssertEqual(ListingWindow.gate(listing: nil, isRestoringSession: false, sessionIdentity: "guest"),
                       .lostListing)
    }

    // MARK: - store：在途请求和会话变化的先后

    /// 扣住每一个请求，由测试决定放行顺序。每个用例结束都 `releaseAll()`——
    /// 一个永远不放行的请求会让等它的任务永远挂着。
    @MainActor final class Gate {
        private var held: [(id: Listing.ID, continuation: CheckedContinuation<Listing, Error>)] = []
        private(set) var requested: [Listing.ID] = []

        func fetch(_ id: Listing.ID) async throws -> Listing {
            requested.append(id)
            return try await withCheckedThrowingContinuation { held.append((id, $0)) }
        }

        func waitForRequests(_ n: Int) async {
            for _ in 0..<500 where requested.count < n { await Task.yield() }
        }

        func releaseOldest(_ result: Result<Listing, Error>) {
            guard !held.isEmpty else { return XCTFail("没有扣着的请求") }
            held.removeFirst().continuation.resume(with: result)
        }

        func releaseAll() {
            while !held.isEmpty { held.removeFirst().continuation.resume(throwing: CancellationError()) }
        }
    }

    private func listing(_ name: String) -> Listing {
        let json = #"{"id":"a","name":"\#(name)","status":"Available to book","url":"","city":"Eindhoven"}"#
        return try! JSONDecoder().decode(Listing.self, from: Data(json.utf8))
    }

    private func store(_ gate: Gate) -> SingleListingStore {
        let s = SingleListingStore()
        s.fetch = gate.fetch
        return s
    }

    func test_退出之后在途请求回来也不能把详情写回去() async {
        let gate = Gate(), store = store(gate)
        let load = Task { await store.load(.init(id: "a", session: "user:k")) }
        await gate.waitForRequests(1)

        store.clear()                                   // 登出
        gate.releaseOldest(.success(listing("旧账号看到的")))
        await load.value

        XCTAssertNil(store.listing, "登出之后回来的结果属于上一个会话，不能显示")
        XCTAssertFalse(store.isLoading)
        gate.releaseAll()
    }

    /// 原先 `load` 开头是 `guard !isLoading`：换号时旧请求还没收尾，新请求被直接挡掉。
    func test_换号时旧请求还在飞_新请求照样发出去_旧数据立刻撤掉() async {
        let gate = Gate(), store = store(gate)
        let first = Task { await store.load(.init(id: "a", session: "user:alice")) }
        await gate.waitForRequests(1)
        gate.releaseOldest(.success(listing("alice 的")))
        await first.value
        XCTAssertEqual(store.listing?.name, "alice 的")

        let slow = Task { await store.load(.init(id: "a", session: "user:alice"), force: true) }
        await gate.waitForRequests(2)
        let switched = Task { await store.load(.init(id: "a", session: "user:bob")) }
        await gate.waitForRequests(3)

        XCTAssertEqual(gate.requested.count, 3, "换号之后的请求被挡掉了——原先就挡在 !isLoading 上")
        XCTAssertNil(store.listing, "换了人，alice 取回来的那份要立刻撤掉，不等 bob 的回来")

        gate.releaseOldest(.success(listing("alice 的（迟到）")))   // 旧的后回来
        gate.releaseOldest(.success(listing("bob 的")))
        await slow.value
        await switched.value
        XCTAssertEqual(store.listing?.name, "bob 的")
        XCTAssertFalse(store.isLoading)
        gate.releaseAll()
    }

    func test_同一份正在取时不重复发请求() async {
        let gate = Gate(), store = store(gate)
        let a = Task { await store.load(.init(id: "a", session: "guest")) }
        await gate.waitForRequests(1)
        let b = Task { await store.load(.init(id: "a", session: "guest")) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(gate.requested.count, 1)
        gate.releaseAll()
        await a.value
        await b.value
    }
}
