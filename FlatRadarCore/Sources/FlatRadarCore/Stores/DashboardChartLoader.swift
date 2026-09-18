import Foundation

/// 首页优先发出三张概览图，最多三个并发请求；每张完成后即可展示。
@MainActor
public enum DashboardChartLoader {
    public static func load(
        fetch: @escaping @Sendable (String, Int) async -> ChartData? = {
            try? await APIClient.shared.getPublicChart(key: $0, days: $1)
        },
        receive: @MainActor (String, ChartData?) -> Void
    ) async {
        let keys = ["daily_new", "source_dist", "status_dist", "price_dist",
                    "type_dist", "energy_dist", "tenant_dist"]
        await withTaskGroup(of: (String, ChartData?).self) { group in
            var next = 0
            func enqueue(_ key: String) {
                group.addTask { (key, await fetch(key, key == "daily_new" ? 7 : 30)) }
            }
            for _ in 0..<3 {
                enqueue(keys[next])
                next += 1
            }
            for await (key, chart) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                receive(key, chart)
                if next < keys.count {
                    enqueue(keys[next])
                    next += 1
                }
            }
        }
    }
}
