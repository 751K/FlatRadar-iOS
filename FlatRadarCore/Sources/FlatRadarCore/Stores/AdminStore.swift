import Foundation

/// 管理面板状态（admin only）。
///
/// 持有
/// - users         : ``GET /admin/users`` 返回的摘要列表
/// - monitorStatus : ``GET /admin/monitor/status``
///
/// 操作（每个动作内部 fetch 最新状态以保 UI 跟数据一致）
/// - toggleUser    : 翻转 enabled
/// - deleteUser    : 删 user
/// - startMonitor / stopMonitor / reloadMonitor : 监控进程控制
@MainActor
@Observable
public final class AdminStore {

    /// 隐式 init 随 `public` 一起变成 internal，宿主 app 构造不了。
    /// 这些 store 的属性全有默认值，空实现与迁移前的隐式构造等价。
    public init() {}
    public var users: [AdminUserSummary] = []
    public var monitorStatus: AdminMonitorStatus?
    public var isLoadingUsers = false
    public var isLoadingMonitor = false
    public var actionInFlight = false
    public var errorMessage: String?

    private let client = APIClient.shared

    // MARK: - Users

    public func fetchUsers() async {
        guard !isLoadingUsers else { return }
        isLoadingUsers = true
        errorMessage = nil
        defer { isLoadingUsers = false }
        do {
            let resp = try await client.adminListUsers()
            users = resp.items
        } catch {
            // 被取消不是失败——见 Error.isCancellation。
            if !error.isCancellation { errorMessage = error.localizedDescription }
            #if DEBUG
            print("[AdminStore] fetchUsers error: \(error)")
            #endif
        }
    }

    /// 翻转用户 enabled；本地立刻 optimistic 更新，失败回滚 + 显示错误。
    public func toggleUser(id: String) async {
        guard users.contains(where: { $0.id == id }) else { return }
        actionInFlight = true
        defer { actionInFlight = false }
        do {
            _ = try await client.adminToggleUser(id: id)
            await fetchUsers()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    public func deleteUser(id: String) async {
        actionInFlight = true
        defer { actionInFlight = false }
        do {
            _ = try await client.adminDeleteUser(id: id)
            users.removeAll { $0.id == id }
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    // MARK: - Monitor

    public func fetchMonitorStatus() async {
        guard !isLoadingMonitor else { return }
        isLoadingMonitor = true
        errorMessage = nil
        defer { isLoadingMonitor = false }
        do {
            monitorStatus = try await client.adminMonitorStatus()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
            #if DEBUG
            print("[AdminStore] fetchMonitorStatus error: \(error)")
            #endif
        }
    }

    /// 启停 / reload 三个动作走同一封装，避免重复 try/catch。
    private func monitorAction(_ block: () async throws -> AdminMonitorActionResponse) async {
        actionInFlight = true
        errorMessage = nil
        defer { actionInFlight = false }
        do {
            _ = try await block()
            // 后端 fork 子进程要几百 ms 才能写出 pidfile；稍等再拉状态更准
            try? await Task.sleep(nanoseconds: 600_000_000)
            await fetchMonitorStatus()
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }

    public func startMonitor() async { await monitorAction(client.adminMonitorStart) }
    public func stopMonitor() async  { await monitorAction(client.adminMonitorStop) }
    public func reloadMonitor() async { await monitorAction(client.adminMonitorReload) }
}
