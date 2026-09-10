import Foundation

/// 管理端用户摘要 —— ``GET /api/v1/admin/users`` 返回的 items 元素。
/// iOS Admin UI 只读展示 + 切 enabled / 删除。完整字段编辑（通知渠道凭证 /
/// 自动预订配置）仍走 Web 后台。
public nonisolated struct AdminUserSummary: Decodable, Identifiable, Hashable, Sendable {

    /// 契约 `AdminUser.required` 的八个——缺了就该响。
    public let id: String
    public let name: String
    public let enabled: Bool
    let notificationsEnabled: Bool
    public let channelCount: Int
    let channels: [String]
    public let activeDevices: Int
    public let filterSummary: AdminFilterSummary

    /// 三个开关都**不在**契约的 `required` 里（`allow_h2s_login` 同理，
    /// 只是包里没接）。合成的 `Decodable` 把它们当必填，缺一个就
    /// `keyNotFound` → 整个 `items` 解不出来 → **用户列表整页打不开**。
    ///
    /// 缺失一律读作 `false`：`AdminUsersView` 用的就是
    /// `if user.autoBookEnabled { 徽章 }` / `if user.appLoginEnabled { 徽章 }`，
    /// 后端没说的时候不标注，正好落进已有的那一支。反过来默认 `true`
    /// 会凭空标出一个没开的开关，比不标更糟。
    public let appLoginEnabled: Bool
    let hasAppPassword: Bool
    public let autoBookEnabled: Bool

    public enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case notificationsEnabled = "notifications_enabled"
        case channelCount = "channel_count"
        case channels
        case appLoginEnabled = "app_login_enabled"
        case hasAppPassword = "has_app_password"
        case activeDevices = "active_devices"
        case autoBookEnabled = "auto_book_enabled"
        case filterSummary = "filter_summary"
    }

    /// 手写而不用合成，理由见上面各属性的注释。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        notificationsEnabled = try c.decode(Bool.self, forKey: .notificationsEnabled)
        channelCount = try c.decode(Int.self, forKey: .channelCount)
        channels = try c.decode([String].self, forKey: .channels)
        activeDevices = try c.decode(Int.self, forKey: .activeDevices)
        filterSummary = try c.decode(AdminFilterSummary.self, forKey: .filterSummary)

        appLoginEnabled = try c.decodeIfPresent(Bool.self, forKey: .appLoginEnabled) ?? false
        hasAppPassword = try c.decodeIfPresent(Bool.self, forKey: .hasAppPassword) ?? false
        autoBookEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoBookEnabled) ?? false
    }
}

/// `AdminUser.filter_summary` 的内容。
///
/// 契约里 `filter_summary` 只写了 `type: "object"`，**一个属性都没声明**——
/// 也就是说它比"required 为空"还弱：契约对这里面有什么**只字未提**。
/// 而这个结构体原先硬要 `cities` / `energy` / `filter_active` 三个键。
/// 这是 ``MapListing`` 那四个"契约里根本不存在的字段"的同一种情况，
/// 所以一并放宽。
public nonisolated struct AdminFilterSummary: Decodable, Hashable, Sendable {
    let maxRent: Double?
    let minArea: Double?
    let minFloor: Int?
    let cities: [String]
    let energy: String
    /// 缺失读作 `false`：`AdminUsersView` 是 `if filterActive { 显示摘要 }`，
    /// 后端没说的时候不显示那一行——凭空显示一句 `—` 更容易被读成"没有筛选"。
    public let filterActive: Bool

    public enum CodingKeys: String, CodingKey {
        case maxRent = "max_rent"
        case minArea = "min_area"
        case minFloor = "min_floor"
        case cities, energy
        case filterActive = "filter_active"
    }

    /// 手写而不用合成，理由见类型注释。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxRent = try c.decodeIfPresent(Double.self, forKey: .maxRent)
        minArea = try c.decodeIfPresent(Double.self, forKey: .minArea)
        minFloor = try c.decodeIfPresent(Int.self, forKey: .minFloor)
        cities = try c.decodeIfPresent([String].self, forKey: .cities) ?? []
        energy = try c.decodeIfPresent(String.self, forKey: .energy) ?? ""
        filterActive = try c.decodeIfPresent(Bool.self, forKey: .filterActive) ?? false
    }

    public var compactDescription: String {
        var parts: [String] = []
        if let r = maxRent { parts.append("≤€\(Int(r))") }
        if let a = minArea { parts.append("≥\(Int(a))m²") }
        if let f = minFloor { parts.append("F≥\(f)") }
        if !cities.isEmpty {
            parts.append(cities.prefix(2).joined(separator: ",")
                + (cities.count > 2 ? "…" : ""))
        }
        if !energy.isEmpty { parts.append("⚡\(energy)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// `GET /api/v1/admin/users` 响应。
nonisolated struct AdminUsersResponse: Decodable, Sendable {
    let items: [AdminUserSummary]
    let total: Int
}

/// `POST /api/v1/admin/users/<id>/toggle` 响应。
nonisolated struct AdminUserToggleResponse: Decodable, Sendable {
    let id: String
    let enabled: Bool
}

/// `DELETE /api/v1/admin/users/<id>` 响应。
nonisolated struct AdminUserDeleteResponse: Decodable, Sendable {
    let deleted: Bool
    let name: String
    let revokedSessions: Int

    enum CodingKeys: String, CodingKey {
        case deleted, name
        case revokedSessions = "revoked_sessions"
    }
}

/// `GET /api/v1/admin/monitor/status` 响应——契约里的 `MonitorStatus`。
///
/// 契约只把 `running` / `pid` 列进 `required`；`last_scrape` 是
/// `["string", "null"]`，而 `last_count` 是 `["string", "integer", "null"]`。
/// 也就是说后端发 `"last_count": 42`（整数，抓到的条数）完全合法，而合成的
/// `Decodable` 会在那里 `typeMismatch`，把整个「监控状态」卡片打成报错——
/// 监控页恰恰是出问题时才去看的那一页。
public nonisolated struct AdminMonitorStatus: Decodable, Sendable {
    public let running: Bool
    public let pid: Int?
    public let lastScrape: String
    /// 归一成字符串：契约允许字符串或整数，界面只是把它印出来
    /// （`AdminMonitorView` 判 `!isEmpty && != "—"`），没有算术需求。
    public let lastCount: String

    public enum CodingKeys: String, CodingKey {
        case running, pid
        case lastScrape = "last_scrape"
        case lastCount = "last_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decode(Bool.self, forKey: .running)
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        lastScrape = try c.decodeIfPresent(String.self, forKey: .lastScrape) ?? ""
        if let s = try? c.decodeIfPresent(String.self, forKey: .lastCount) {
            lastCount = s
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .lastCount) {
            lastCount = String(n)
        } else {
            lastCount = ""
        }
    }
}

/// `POST /api/v1/admin/monitor/{start|stop|reload}` 响应。
nonisolated struct AdminMonitorActionResponse: Decodable, Sendable {
    let started: Bool?
    let stopped: Bool?
    let pid: Int?
    let reload: Bool?
    let method: String?     // "signal" / "file"
}
