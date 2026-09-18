import XCTest
import FlatRadarCore
@testable import FlatRadarMac

/// 快速切换统计时间范围（代码审查 P2）。
///
/// 原先 `load()` 开头是 `guard !isLoading`：30 天那批还在路上时点 7d，新请求被这一句
/// 挡掉；30 天那批回来后照常写进 `charts`。结果 Picker 停在 7d、图是 30 天的，
/// 而且不会补发。
@MainActor
final class StatsWindowSwitchTests: XCTestCase {

    /// 扣住每一个图表请求，由测试决定哪个时间窗先回来。
    ///
    /// 每个用例结束都 `releaseAll()`——被扣着不放的请求会让等它的任务永远挂着，
    /// 上一轮就是这么把整个测试进程挂了十几分钟。
    @MainActor final class Gate {
        private var held: [(days: Int, continuation: CheckedContinuation<[ChartEntry]?, Never>)] = []
        private(set) var requested: [Int] = []

        func fetch(_ key: String, _ days: Int) async -> [ChartEntry]? {
            requested.append(days)
            return await withCheckedContinuation { held.append((days, $0)) }
        }

        func count(days: Int) -> Int { requested.filter { $0 == days }.count }

        /// 等到某个时间窗的请求全发出来。有上限，等不到就返回，由断言去报。
        func waitForRequests(days: Int, _ n: Int) async {
            for _ in 0..<2000 where count(days: days) < n { await Task.yield() }
        }

        /// 放行某个时间窗的全部请求。每张图回一条，数量 = 天数，好认出是哪一批。
        func release(days: Int) {
            let mine = held.filter { $0.days == days }
            held.removeAll { $0.days == days }
            for h in mine { h.continuation.resume(returning: [ChartEntry(label: "x", count: days)]) }
        }

        func releaseAll() {
            let all = held
            held.removeAll()
            for h in all { h.continuation.resume(returning: nil) }
        }
    }

    private func model(_ gate: Gate) -> StatsModel {
        let m = StatsModel()
        m.fetchChart = { key, days in await gate.fetch(key, days) }
        return m
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2000 where !condition() { await Task.yield() }
    }

    func test_加载中切到7天_显示的是7天_旧的30天回来也不写() async {
        let gate = Gate(), stats = model(gate)
        defer { gate.releaseAll() }
        let n = StatsModel.keys.count

        let first = Task { await stats.load() }            // 默认 30 天
        await gate.waitForRequests(days: 30, n)

        stats.days = .week                                 // 30 天还在路上
        await gate.waitForRequests(days: 7, n)
        XCTAssertEqual(gate.count(days: 7), n, "换窗之后必须真的补发 7 天的请求——原先被 isLoading 挡掉了")

        gate.release(days: 30)                             // 旧的先回来
        await first.value
        XCTAssertNotEqual(stats.chartsWindow, .month, "30 天那批是过期结果，不能写进屏上")
        XCTAssertNotEqual(stats.sampleSize, 30)
        XCTAssertTrue(stats.isLoading, "7 天那批还没回来，不能被过期结果标成已加载完")

        gate.release(days: 7)
        await waitUntil { !stats.isLoading }
        XCTAssertEqual(stats.chartsWindow, .week)
        XCTAssertEqual(stats.sampleSize, 7)
        XCTAssertFalse(stats.failed)
    }

    func test_新窗先回来_旧窗后回来也盖不掉它() async {
        let gate = Gate(), stats = model(gate)
        defer { gate.releaseAll() }
        let n = StatsModel.keys.count

        let first = Task { await stats.load() }
        await gate.waitForRequests(days: 30, n)
        stats.days = .quarter
        await gate.waitForRequests(days: 90, n)

        gate.release(days: 90)
        await waitUntil { stats.chartsWindow == .quarter }
        gate.release(days: 30)
        await first.value

        XCTAssertEqual(stats.chartsWindow, .quarter)
        XCTAssertEqual(stats.sampleSize, 90)
        XCTAssertFalse(stats.isLoading)
    }

    func test_新窗全挂了_不能留着旧窗的图冒充新窗() async {
        let gate = Gate(), stats = model(gate)
        defer { gate.releaseAll() }
        let n = StatsModel.keys.count

        let first = Task { await stats.load() }
        await gate.waitForRequests(days: 30, n)
        gate.release(days: 30)
        await first.value
        XCTAssertEqual(stats.chartsWindow, .month)

        stats.days = .week
        await gate.waitForRequests(days: 7, n)
        gate.releaseAll()                                  // 7 天一张都没拿到
        await waitUntil { !stats.isLoading }

        XCTAssertTrue(stats.failed)
        XCTAssertTrue(stats.charts.isEmpty, "Picker 已经指着 7 天，屏上不能还是 30 天的图")
        XCTAssertNil(stats.chartsWindow)
    }

    func test_同一个窗已经在取_不重复发() async {
        let gate = Gate(), stats = model(gate)
        defer { gate.releaseAll() }
        let n = StatsModel.keys.count

        let a = Task { await stats.load() }
        await gate.waitForRequests(days: 30, n)
        let b = Task { await stats.load() }                // 比如切屏回来又触发了一次
        await b.value
        XCTAssertEqual(gate.count(days: 30), n, "同一个窗在路上时，不带 force 的 load 不该再发一轮")

        gate.release(days: 30)
        await a.value
        XCTAssertEqual(stats.chartsWindow, .month)
    }
}
