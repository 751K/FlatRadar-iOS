import Foundation
import UserNotifications

@MainActor
@Observable
public final class NotificationsStore {

    /// 隐式 init 随 `public` 一起变成 internal，宿主 app 构造不了。
    /// 这些 store 的属性全有默认值，空实现与迁移前的隐式构造等价。
    public init() {}
    public var notifications: [NotificationItem] = []
    /// 未读计数；每次写入自动同步到 App 图标 badge。
    public var unreadCount = 0 {
        didSet { syncAppBadge() }
    }
    public var total = 0
    public var isLoading = false
    public var isLoadingMore = false
    public var errorMessage: String?
    public var lastError: APIError?
    public var revision: UInt64 = 0

    // SSE 实时流状态
    var isStreamConnected = false
    var streamError: String?

    private let client = APIClient.shared
    // Injectable boundaries keep request-order tests independent of the network and OS badge.
    @ObservationIgnored var loadPage: (Int, Int) async throws -> NotificationsResponse = { limit, offset in
        try await APIClient.shared.getNotifications(limit: limit, offset: offset)
    }
    @ObservationIgnored var markReadRequest: ([Int]?) async throws -> Void = { ids in
        _ = try await APIClient.shared.markNotificationsRead(ids: ids)
    }
    @ObservationIgnored var updateBadge: (Int) async throws -> Void = { count in
        try await UNUserNotificationCenter.current().setBadgeCount(count)
    }
    private var requestGeneration: UInt64 = 0
    private let pageSize = 50

    // SSE 后台任务句柄；登出 / 切后台时取消
    private var streamTask: Task<Void, Never>?

    // "补齐未读页"的后台任务句柄；每次 fetch 重启，避免并发叠加。
    private var backfillTask: Task<Void, Never>?

    // 后台补未读页的安全上限——未读极多时（比如几百条历史未读）不该串行
    // 拉几十页拖垮网络/电量。封顶后用户照常下拉/滚动 loadMore() 继续。
    private let maxBackfillPages = 5

    var hasMore: Bool { notifications.count < total }

    private var loadedUnreadCount: Int {
        notifications.reduce(0) { $0 + ($1.isRead ? 0 : 1) }
    }

    public func fetch() async {
        requestGeneration &+= 1
        let generation = requestGeneration
        backfillTask?.cancel()
        backfillTask = nil
        isLoadingMore = false
        isLoading = true
        errorMessage = nil
        defer {
            if generation == requestGeneration { isLoading = false }
        }
        do {
            let resp = try await loadPage(pageSize, 0)
            guard generation == requestGeneration, !Task.isCancelled else { return }
            notifications = resp.items
            total = resp.total
            unreadCount = resp.unread
            lastError = nil
            revision &+= 1
            // Only a successful, current first page may start background pagination.
            backfillTask = Task { [weak self] in
                await self?.loadMoreUntilUnreadIsVisible(generation: generation)
            }
        } catch {
            guard generation == requestGeneration else { return }
            // 被取消不是失败——见 Error.isCancellation。
            if !error.isCancellation {
                lastError = error as? APIError
                errorMessage = error.localizedDescription
            }
        }
    }

    public func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading, !Task.isCancelled else { return }
        let generation = requestGeneration
        isLoadingMore = true
        defer {
            if generation == requestGeneration { isLoadingMore = false }
        }
        do {
            let resp = try await loadPage(pageSize, notifications.count)
            guard generation == requestGeneration, !Task.isCancelled else { return }
            notifications.append(contentsOf: resp.items)
            total = resp.total
            revision &+= 1
        } catch {
            guard generation == requestGeneration else { return }
            #if DEBUG
            print("[NotificationsStore] loadMore failed: \(error)")
            #endif
        }
    }

    private func loadMoreUntilUnreadIsVisible(generation: UInt64) async {
        var pagesLoaded = 0
        while unreadCount > loadedUnreadCount, notifications.count < total {
            // 取消（登出 / 新一轮 fetch / 视图消失）或触顶 → 立即停。
            guard generation == requestGeneration, !Task.isCancelled,
                  !isLoadingMore, pagesLoaded < maxBackfillPages else { break }
            let before = notifications.count
            await loadMore()
            guard generation == requestGeneration, notifications.count > before else { break }
            pagesLoaded += 1
        }
    }

    public func refresh() async {
        await fetch()
    }

    public func markRead(ids: [Int]) async {
        guard !ids.isEmpty else { return }
        let generation = requestGeneration
        do {
            try await markReadRequest(ids)
            guard generation == requestGeneration, !Task.isCancelled else { return }
            let idSet = Set(ids)
            // 翻状态时**当场算这次新增了多少 "from unread to read"**，
            // 直接拿来减 unreadCount。避免之前每次 O(n) 重扫整张列表，也对
            // SSE 并发更稳：SSE handleSSEData 是用 += 增量更新 unreadCount 的，
            // 这里用 -= 增量减，跟它对称，不会用 filter().count 覆盖 SSE 期间
            // 的增量。
            var transitioned = 0
            for i in notifications.indices where idSet.contains(notifications[i].id) {
                if !notifications[i].isRead {
                    transitioned += 1
                }
                notifications[i] = notifications[i].markedRead()
            }
            unreadCount = max(0, unreadCount - transitioned)
            if transitioned > 0 { revision &+= 1 }
        } catch {
            // Non-critical; user can retry
        }
    }

    public func markAllRead() async {
        let generation = requestGeneration
        do {
            try await markReadRequest(nil)
            guard generation == requestGeneration, !Task.isCancelled else { return }
            // Optimistic local update
            //
            // 整批换一次，不逐条赋值：逐条写的话，被观察的数组每条都发一次变更，
            // 两千条就是两千次。已读的原样留着；`markedRead()` 本身也只翻一个字段，
            // 不再重跑分类、正则和日期解析（见那里的说明）。
            notifications = notifications.map { $0.isRead ? $0 : $0.markedRead() }
            unreadCount = 0
            revision &+= 1
        } catch {
            // Non-critical
        }
    }

    // MARK: - SSE 实时流

    /// 启动 SSE 连接（幂等：已连/任务在跑时直接返回）。
    /// guest 角色不该调（没 token，stream 会 401）。
    public func connectStream() {
        guard streamTask == nil else { return }
        guard client.currentToken() != nil else {
            #if DEBUG
            print("[SSE] no token, skip connect")
            #endif
            return
        }
        streamTask = Task { [weak self] in
            await self?.streamLoop()
        }
    }

    /// 登出时清空：先断 SSE 再清数据，避免断开期间还有 handleSSEData 写入旧值。
    /// 注意 unreadCount = 0 会触发 didSet → syncAppBadge → 同步 App 角标到 0。
    public func clear() {
        // In-flight HTTP requests may complete even after their caller is cancelled.
        requestGeneration &+= 1
        disconnectStream()
        notifications = []
        total = 0
        unreadCount = 0
        isLoading = false
        isLoadingMore = false
        errorMessage = nil
        lastError = nil
        streamError = nil
        revision &+= 1
    }

    /// 主动停掉 SSE（登出 / 切后台）。同时取消后台补页任务，避免登出后
    /// 仍在偷偷拉分页。
    public func disconnectStream() {
        streamTask?.cancel()
        streamTask = nil
        backfillTask?.cancel()
        backfillTask = nil
        isStreamConnected = false
    }

    /// 重连退避循环。后端单连接 300s 主动关闭让浏览器自然重连——
    /// iOS 这边一样：throw 后等几秒再连。指数退避，上限 60s。
    private func streamLoop() async {
        var backoff: UInt64 = 2_000_000_000   // 2s
        while !Task.isCancelled {
            do {
                try await runStreamOnce()
                try Task.checkCancellation()
                // 正常返回（服务端 maxage 到了）→ 短暂等待再连
                backoff = 2_000_000_000
                isStreamConnected = false
                streamError = nil
                try? await Task.sleep(nanoseconds: 500_000_000)
            } catch is CancellationError {
                break
            } catch {
                guard !Task.isCancelled else { break }
                isStreamConnected = false
                streamError = error.localizedDescription
                #if DEBUG
                print("[SSE] stream error: \(error); reconnect in \(backoff / 1_000_000_000)s")
                #endif
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 60_000_000_000)
            }
        }
    }

    private func runStreamOnce() async throws {
        try Task.checkCancellation()
        // 进函数立刻 snapshot lastId；之前 maxId 是 computed property，
        // 在 runStreamOnce 内部多处读会随 notifications 变化（handleSSEData
        // 边塞数据 边可能撞）。snapshot 一次保证本次连接生命周期内 lastId
        // 始终是建立连接时刻的值。
        let lastId = notifications.first?.id ?? 0
        let url = client.notificationsStreamURL(lastId: lastId)
        let token = client.currentToken()
        let sse = SSEClient(url: url, bearerToken: token)
        #if DEBUG
        print("[SSE] connecting \(url.absoluteString)")
        #endif
        isStreamConnected = true
        streamError = nil

        for try await event in sse.events() {
            try Task.checkCancellation()
            switch event {
            case .data(let payload):
                // 解码放到主线程外：一批里每条都要分类、跑标题正则、解析日期
                // （无时区的格式要逐个试备用解析器），原先整批都在主线程上做。
                // 在这里 await，事件仍是一批一批按顺序处理的。
                let decoded = await Self.decodeBatch(payload)
                try Task.checkCancellation()
                handleSSEData(decoded, raw: payload)
            case .keepalive:
                continue   // 保活心跳，无操作
            case .retry:
                continue   // 服务端建议重连间隔，我们的退避已自行处理
            }
        }
    }

    /// 后端推过来的 ``data:`` payload 是 ``list[NotificationItem]`` JSON。
    /// 多条按 id 升序，我们要插到本地列表顶部（新的在前）。
    // MARK: - App icon badge

    /// 把 ``unreadCount`` 同步到 App 图标右上角的红点数字。
    /// 要求用户已授予 ``.badge`` 权限（PushStore.requestPermissionAndRegister 已经申请过）。
    /// 失败安静吞（权限被撤是常见情况，UI 上 tab badge 仍正常显示）。
    private func syncAppBadge() {
        let n = unreadCount
        let generation = requestGeneration
        // 显式 @MainActor —— setBadgeCount 是 MainActor-isolated API。
        // 不写 @MainActor 在 Swift 6 strict concurrency 下报错；
        // 写了在 Swift 5 模式下也不会有负面影响。
        Task { @MainActor in
            guard generation == requestGeneration, n == unreadCount else { return }
            do {
                try await updateBadge(n)
            } catch {
                // 用户拒了 badge 权限 / iOS < 16 → 静默
            }
        }
    }

    /// SSE 的一批 `data:`，在**主线程外**解码。
    @concurrent
    nonisolated static func decodeBatch(_ payload: String) async -> Result<[NotificationItem], Error> {
        Result { try JSONDecoder().decode([NotificationItem].self, from: Data(payload.utf8)) }
    }

    /// 解码好的一批并进列表。这一步碰的是界面状态，留在主线程。
    private func handleSSEData(_ decoded: Result<[NotificationItem], Error>, raw payload: String) {
        do {
            let incoming = try decoded.get()
            if incoming.isEmpty { return }
            let existing = Set(notifications.map(\.id))
            let fresh = incoming.filter { !existing.contains($0.id) }
            if fresh.isEmpty { return }
            // 后端按 id ASC 排；本地列表按时间 DESC，所以反转
            notifications.insert(contentsOf: fresh.reversed(), at: 0)
            total += fresh.count
            unreadCount += fresh.filter { !$0.isRead }.count
            revision &+= 1
            #if DEBUG
            print("[SSE] +\(fresh.count) new notifications (total=\(total))")
            #endif
        } catch {
            // Schema 漂移 / 后端发出畸形 JSON → 写到 streamError 让 UI 能展示，
            // 不再仅 debug print 静默吞。生产 release 模式下也会进 Logger。
            streamError = "Notification stream parse error"
            #if DEBUG
            print("[SSE] decode error: \(error); raw=\(payload.prefix(200))")
            #endif
        }
    }
}
