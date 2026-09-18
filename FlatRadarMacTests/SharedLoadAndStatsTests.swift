import XCTest
import FlatRadarCore
@testable import FlatRadarMac

// MARK: - 第二个窗口不再重复加载共享数据

/// 打开第二个窗口会重复加载共享数据（代码审查）。
///
/// `loadOnce()` 原先既没有"已经加载过"的标记，也没有把进行中的那一趟合并。
@MainActor
final class SharedLoadTests: XCTestCase {

    /// 一扇门：加载闭包在门口等着，测试决定什么时候放行。收尾一定 `open()`。
    @MainActor final class Door {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func open() {
            isOpen = true
            while !waiting.isEmpty { waiting.removeFirst().resume() }
        }
    }

    @MainActor final class Counter { var runs = 0 }

    private func settle() async { for _ in 0..<50 { await Task.yield() } }

    func test_同一个会话_第二个窗口等第一趟_不另起一趟() async {
        let feed = AppFeed(), door = Door()
        defer { door.open() }
        let c = Counter()

        let first = Task { await feed.loadShared(session: "user:k") { c.runs += 1; await door.wait() } }
        await settle()
        let second = Task { await feed.loadShared(session: "user:k") { c.runs += 1 } }
        await settle()
        XCTAssertEqual(c.runs, 1, "第二个窗口把摘要、走势图、通知、匹配数又请求了一遍")

        door.open()
        await first.value
        await second.value

        // 两个窗口都在之后，再开第三个：已经加载过了，直接用。
        await feed.loadShared(session: "user:k") { c.runs += 1 }
        XCTAssertEqual(c.runs, 1)
    }

    func test_换了一个人_重新加载() async {
        let feed = AppFeed()
        let c = Counter()
        await feed.loadShared(session: "guest") { c.runs += 1 }
        await feed.loadShared(session: "user:k") { c.runs += 1 }
        XCTAssertEqual(c.runs, 2, "游客注册成正式用户之后，共享数据得按新身份再取一次")
    }

    func test_登出之后同一个人再登录_重新加载() async {
        let feed = AppFeed()
        let c = Counter()
        await feed.loadShared(session: "user:k") { c.runs += 1 }
        feed.signedOut()
        await feed.loadShared(session: "user:k") { c.runs += 1 }
        XCTAssertEqual(c.runs, 2, "登出清掉了数据，再登录不重取的话窗口里是空的")
    }
}

// MARK: - 统计页到一张画一张

/// 统计页必须等待最慢的图表请求才能显示内容（代码审查）。
@MainActor
final class StatsProgressiveTests: XCTestCase {

    /// 按"哪张图、哪个时间窗"扣住请求。收尾一定 `releaseAll()`。
    @MainActor final class Gate {
        private var held: [(key: String, days: Int, c: CheckedContinuation<[ChartEntry]?, Never>)] = []
        private(set) var requested = 0

        func fetch(_ key: String, _ days: Int) async -> [ChartEntry]? {
            requested += 1
            return await withCheckedContinuation { held.append((key, days, $0)) }
        }

        func waitForRequests(_ n: Int) async {
            for _ in 0..<2000 where requested < n { await Task.yield() }
        }

        func release(_ key: String, days: Int) {
            guard let i = held.firstIndex(where: { $0.key == key && $0.days == days }) else {
                return XCTFail("没有扣着 \(key)/\(days)")
            }
            held.remove(at: i).c.resume(returning: [ChartEntry(label: "x", count: days)])
        }

        func releaseAll() {
            let all = held
            held.removeAll()
            for h in all { h.c.resume(returning: nil) }
        }
    }

    private func stats(_ gate: Gate) -> StatsModel {
        let m = StatsModel()
        m.fetchChart = { key, days in await gate.fetch(key, days) }
        return m
    }

    private func settle() async { for _ in 0..<200 { await Task.yield() } }

    func test_十一张到了就先画出来_不等最慢那张() async {
        let gate = Gate(), m = stats(gate)
        defer { gate.releaseAll() }
        let keys = StatsModel.keys
        let load = Task { await m.load() }
        await gate.waitForRequests(keys.count)

        for key in keys.dropLast() { gate.release(key, days: 30) }
        await settle()
        XCTAssertEqual(m.charts.count, keys.count - 1, "十一张早到了，屏上却还是空的")
        XCTAssertTrue(m.isLoading)
        XCTAssertEqual(m.pendingKeys, [keys.last!], "最慢那张要画占位")

        gate.release(keys.last!, days: 30)
        await load.value
        XCTAssertEqual(m.charts.count, keys.count)
        XCTAssertTrue(m.pendingKeys.isEmpty)
        XCTAssertFalse(m.isLoading)
    }

    func test_换窗后到一张_旧窗的图整批撤下_不混着画() async {
        let gate = Gate(), m = stats(gate)
        defer { gate.releaseAll() }
        let keys = StatsModel.keys
        let first = Task { await m.load() }
        await gate.waitForRequests(keys.count)
        for key in keys { gate.release(key, days: 30) }
        await first.value
        XCTAssertEqual(m.chartsWindow, .month)

        m.days = .week
        await gate.waitForRequests(keys.count * 2)
        XCTAssertEqual(m.charts.count, keys.count, "新窗一张都还没到时，照旧显示旧窗那批")

        gate.release(keys[0], days: 7)
        await settle()
        XCTAssertEqual(m.chartsWindow, .week)
        XCTAssertEqual(Array(m.charts.keys), [keys[0]], "7 天和 30 天拼在了同一屏上")
        XCTAssertEqual(m.charts[keys[0]]?.first?.count, 7)
    }
}
