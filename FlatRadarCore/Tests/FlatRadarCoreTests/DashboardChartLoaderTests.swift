import XCTest
@testable import FlatRadarCore

@MainActor
final class DashboardChartLoaderTests: XCTestCase {
    @MainActor private final class Gate {
        var pending: [String: CheckedContinuation<ChartData?, Never>] = [:]
        var requested: [(String, Int)] = []
        var peak = 0
        func fetch(_ key: String, _ days: Int) async -> ChartData? {
            requested.append((key, days))
            return await withCheckedContinuation {
                pending[key] = $0
                peak = max(peak, pending.count)
            }
        }
        func finish(_ key: String) {
            pending.removeValue(forKey: key)?.resume(returning: ChartData(key: key, days: 7, data: []))
        }
        func finishAll() {
            let keys = Array(pending.keys)
            for key in keys { finish(key) }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2000 {
            if condition() { return }
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }

    func testFastChartIsPublishedWhileSlowChartsArePendingAndConcurrencyIsBounded() async {
        let gate = Gate()
        var received: [String] = []
        let task = Task {
            await DashboardChartLoader.load(fetch: { await gate.fetch($0, $1) }) { key, chart in
                XCTAssertEqual(chart?.key, key)
                received.append(key)
            }
        }
        await waitUntil { gate.pending.count == 3 }
        XCTAssertEqual(Set(gate.pending.keys), ["daily_new", "source_dist", "status_dist"])
        gate.finish("daily_new")
        await waitUntil { received == ["daily_new"] && gate.requested.count == 4 }
        XCTAssertNotNil(gate.pending["source_dist"], "快图无需等待其它首页图")
        for key in ["price_dist", "type_dist", "energy_dist", "tenant_dist"] {
            await waitUntil { gate.pending[key] != nil }
            gate.finish(key)
        }
        gate.finishAll()
        await task.value
        XCTAssertEqual(received.count, 7)
        XCTAssertEqual(gate.peak, 3)
        XCTAssertEqual(gate.requested.first { $0.0 == "daily_new" }?.1, 7)
        XCTAssertTrue(gate.requested.filter { $0.0 != "daily_new" }.allSatisfy { $0.1 == 30 })
    }

    func testCancellationDoesNotPublishLateResponsesOrScheduleRemainingCharts() async {
        let gate = Gate()
        var received = 0
        let task = Task {
            await DashboardChartLoader.load(fetch: { await gate.fetch($0, $1) }) { _, _ in received += 1 }
        }
        await waitUntil { gate.pending.count == 3 }
        task.cancel()
        gate.finishAll()
        await task.value
        XCTAssertEqual(received, 0)
        XCTAssertEqual(gate.requested.count, 3)
    }
}
