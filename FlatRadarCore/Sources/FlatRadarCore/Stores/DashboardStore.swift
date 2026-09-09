import Foundation

@MainActor
@Observable
public final class DashboardStore {

    /// 隐式 init 随 `public` 一起变成 internal，宿主 app 构造不了。
    /// 这些 store 的属性全有默认值，空实现与迁移前的隐式构造等价。
    public init() {}
    public var summary: MonitorStatus?
    public var meSummary: MeSummary?
    var chartKeys: [String] = []
    var selectedChart: ChartData?
    public var isLoading = false
    var isLoadingChart = false
    public var errorMessage: String?
    public var lastError: APIError?

    private let client = APIClient.shared

    public func fetchSummary() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // 加单次重试 —— 后端冷启动 / 网络抖动单次失败很常见，第二次通常就过。
        // 失败两次再把错误吐出来。
        for attempt in 0..<2 {
            do {
                summary = try await client.getPublicSummary()
                lastError = nil
                errorMessage = nil
                return
            } catch {
                #if DEBUG
                print("[DashboardStore] fetchSummary attempt \(attempt + 1) failed: \(error.localizedDescription)")
                #endif
                // 被取消不是失败，而且重试也一定是取消——`defer` 会收掉
                // isLoading，直接退出。见 Error.isCancellation。
                if error.isCancellation { return }
                if attempt == 1 {
                    lastError = error as? APIError
                    errorMessage = error.localizedDescription
                } else {
                    // 0.6s 退避，给后端 / 网络一个喘息
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
            }
        }
    }

    public func fetchMeSummary() async {
        do {
            meSummary = try await client.getMeSummary()
        } catch {
            // me summary is additive; failure keeps public summary visible
        }
    }

    func fetchChartKeys() async {
        do {
            chartKeys = try await client.getPublicCharts()
        } catch {
            // Chart keys are non-critical; don't set errorMessage
        }
    }

    func fetchChart(key: String, days: Int = 30) async {
        isLoadingChart = true
        do {
            selectedChart = try await client.getPublicChart(key: key, days: days)
        } catch {
            // Chart detail failure is non-critical
        }
        isLoadingChart = false
    }

    /// 登出时清空——summary 是 public，但 meSummary 是用户私有的，必须清。
    /// 全部清掉省得分两类。
    public func clear() {
        summary = nil
        meSummary = nil
        chartKeys = []
        selectedChart = nil
        isLoading = false
        isLoadingChart = false
        errorMessage = nil
        lastError = nil
    }
}
