import Foundation

public enum ServerTime {
    public nonisolated static let timeZone = TimeZone(identifier: "Europe/Amsterdam") ?? .current

    /// **全 App 唯一的「服务端日历」。**
    ///
    /// 后端发的日期字符串按 Europe/Amsterdam 解读，房源的「可入住日」也是那个
    /// 时区里的日子。凡是要回答「这是几月」「这是哪一天」的地方都得用它，
    /// 不能用 `Calendar.current`。
    ///
    /// 为什么要收成一份：`CalendarView` 用的是这个时区，`NativeMonthCalendar`
    /// 用的是 `Calendar.current`，两者在**月初那一刻**会差整整一个月——
    /// 9 月 1 日 00:00 阿姆斯特丹 = 8 月 31 日 22:00 UTC，用 UTC 去读就是 8 月。
    ///
    /// 那正是 build 295→307 里日历始终停在 8 月的原因。真机在阿姆时区上看不到
    /// （读回来正好是 9 月 1 日），只有 CI 的模拟器复现——我据此猜了五轮
    /// 「UICalendarView 的吸附时机」，全是错的。两个日历只要还是两份，
    /// 这类"只在某些时区出现"的错就会继续冒出来。
    public nonisolated static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }()

    // MARK: - Static formatters (DateFormatter creation is expensive)
    //
    // Swift 6 strict concurrency 下，static let 默认走 MainActor 隔离，但
    // display(_:) / parse(_:) 等是 nonisolated，跨不过去 → 编译错。
    // 加 `nonisolated` 关键字解除隔离。

    /// ISO8601 两种形态：带小数秒和不带。后端两种都发过，所以两个都留着。
    ///
    /// 用 `Date.ISO8601FormatStyle` 而不是 `ISO8601DateFormatter`：
    ///
    /// - 它是 **`Sendable` 的值类型**，`nonisolated` 就够了，不必再挂
    ///   `(unsafe)` 去关掉并发检查。工程里最后几个 `nonisolated(unsafe)` 全是
    ///   为这个旧类留的。
    /// - `includingFractionalSeconds` 之外的默认值正好等于
    ///   `.withInternetDateTime`：dateSeparator `-`、dateTimeSeparator `T`、
    ///   timeSeparator `:`、timeZoneSeparator 省略、时区 UTC。所以这是**行为
    ///   等价**的替换，不是"差不多"。
    nonisolated private static let isoFrac =
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    nonisolated private static let isoNoFrac =
        Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    nonisolated private static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// `2026-09-17` → 那一天在 **Europe/Amsterdam** 的 00:00。
    ///
    /// 图表要把 `daily_new` 画成连续的时间轴才好抽稀刻度（分类轴一根柱子标一个，
    /// 31 个日期会糊成一条带）。开出来是为了让调用方**别自己再造一个
    /// `DateFormatter`**——后端的日期是按阿姆斯特丹时区分的桶，用本地时区解析会
    /// 在月初差一天。
    public nonisolated static func day(from raw: String) -> Date? {
        dateParser.date(from: raw)
    }

    nonisolated private static let displayFormatterTZ: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = .autoupdatingCurrent
        f.timeZone = timeZone
        f.dateFormat = "MMM d, HH:mm zzz"
        return f
    }()

    nonisolated private static let displayFormatterNoTZ: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = .autoupdatingCurrent
        f.timeZone = timeZone
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    nonisolated private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = .autoupdatingCurrent
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    nonisolated private static let fallbackParsers: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = fmt
            return f
        }
    }()

    // MARK: - Public API

    public nonisolated static func display(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "--", trimmed != "—" else { return raw }
        if isDateOnly(trimmed) {
            return displayDate(trimmed)
        }
        guard let date = parse(trimmed) else { return raw }

        let fmt = shouldShowTimeZone(for: date) ? displayFormatterTZ : displayFormatterNoTZ
        return fmt.string(from: date)
    }

    /// 「入住日未定」的哨兵年份。
    ///
    /// H2S 在入住日未定时发的是 `2050-01-01`。scraper、存储层、booker 都认得它，
    /// 唯独界面把它当成一个日期显示——地图弹卡和房源详情都写着「2050 年 1 月 1 日
    /// 可入住」，读起来像一个（荒唐的）事实，而它的意思其实是「不知道」。
    ///
    /// 按**年份**判而不是精确匹配那一天，哨兵改成 2099 时不至于漏。判据与
    /// `models.SENTINEL_AVAILABLE_FROM_YEAR`、`app.js` 的
    /// `SENTINEL_AVAILABLE_FROM_YEAR` 保持一致。
    nonisolated static let sentinelAvailableFromYear = 2050

    /// 这个 `available_from` 是不是哨兵（而不是真日期）。
    public nonisolated static func isSentinelDate(_ raw: String?) -> Bool {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, let year = Int(trimmed.prefix(4)) else { return false }
        return year >= sentinelAvailableFromYear
    }

    /// 显示用日期。哨兵返回 "—"，不冒充成一个日期。
    ///
    /// **不加 `dash:` 之类的默认参数**：带默认值的函数引用没法当
    /// `(String) -> String` 传，而 `availableFrom.map(ServerTime.displayDate)`
    /// 这种写法在详情页有两处。
    public nonisolated static func displayDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        if isSentinelDate(trimmed) { return "—" }
        let source = String(trimmed.prefix(10))

        guard let date = dateParser.date(from: source) else { return raw }
        return mediumDateFormatter.string(from: date)
    }

    nonisolated private static func shouldShowTimeZone(for date: Date) -> Bool {
        TimeZone.current.secondsFromGMT(for: date) != timeZone.secondsFromGMT(for: date)
    }

    nonisolated private static func isDateOnly(_ raw: String) -> Bool {
        raw.count == 10 && raw.dropFirst(4).first == "-" && raw.dropFirst(7).first == "-"
    }

    nonisolated private static func parse(_ raw: String) -> Date? {
        if let date = try? isoFrac.parse(raw) { return date }
        if let date = try? isoNoFrac.parse(raw) { return date }

        for f in fallbackParsers {
            if let date = f.date(from: raw) { return date }
        }
        return nil
    }

    /// "2m ago" / "1h ago" / "3d ago" style relative time from ISO 8601.
    public nonisolated static func relativeTime(_ iso: String) -> String {
        relativeTime(iso, now: Date())
    }

    /// 同上，但「现在」是传进来的。
    ///
    /// 小组件需要它。WidgetKit **提前**渲染视图，到了时间轴上那个点才把它贴上屏：
    /// 视图体里写 `Date()` 拿到的是**渲染**那一刻，不是读者**看见**那一刻。一条
    /// 半小时后才上屏的 "scanned 4m ago" 仍然写着 4m，而它已经是 34m 了。所以那边
    /// 每个时间轴条目自带「打算什么时候显示」，文字按那个时刻算。
    ///
    /// 顺带这是 `relativeTime` 第一次可测：原来那版把 `Date()` 焊死在函数体里，
    /// 除了 `0s ago` 之外没有一档能断言——四个分档里有三档从来没被测过。
    public nonisolated static func relativeTime(_ iso: String, now: Date) -> String {
        guard !iso.isEmpty, iso != "--" else { return "--" }
        guard let date = parse(iso) else { return iso }
        return ago(seconds: now.timeIntervalSince(date))
    }

    /// 已经是 `Date` 的时间点走这条，不必先格式化成字符串再解析回来。
    ///
    /// 和上面**共用同一套分档**，所以「后端什么时候扫的」和「这份数据什么时候
    /// 取的」两句话的措辞不会漂成两套。
    public nonisolated static func relativeTime(since date: Date, now: Date) -> String {
        ago(seconds: now.timeIntervalSince(date))
    }

    /// 紧凑年龄串：`now` / `38m` / `5h` / `2d`，超过一周退回具体日期。
    ///
    /// 和 ``relativeTime(_:now:)`` 是**两种格式**，都留着：那个是"距今多久"的
    /// 完整说法（`4m ago`），用在一句话里；这个是贴在列表行尾的一小格，
    /// 空间只够两三个字符。``NotificationItem/ageText`` 和小组件的 NEWEST
    /// 三行读的是同一份，所以两处不会写出两种写法。
    ///
    /// `now` 传进来的理由和 `relativeTime` 一样：WidgetKit 提前渲染，
    /// 视图体里的 `Date()` 是渲染那一刻，不是读者看见那一刻。
    public nonisolated static func compactAge(_ iso: String, now: Date) -> String {
        guard let date = parse(iso) else { return "" }
        return compactAge(since: date, now: now)
    }

    public nonisolated static func compactAge(since date: Date, now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 86400 * 7 { return "\(Int(interval / 86400))d" }
        return shortDate(date)
    }

    nonisolated private static let compactDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    /// `4 Sep`。柱子两端的标签、日历那格的头条日期都用它。
    ///
    /// `public`：小组件够不着包外的 formatter，而它必须和包里其它日期走同一个
    /// 时区（后端按 Europe/Amsterdam 分桶，用本地时区会在月初差一天）。
    public nonisolated static func shortDate(_ date: Date) -> String {
        compactDateFormatter.string(from: date)
    }

    /// 分档本身。`max(0,)` 挡的是时钟回拨和服务端时间略微超前——那时候差值是负的，
    /// 不挡就会显示 `-3s ago`。
    private nonisolated static func ago(seconds: TimeInterval) -> String {
        let secs = max(0, Int(seconds))
        switch secs {
        case 0..<60: return "\(secs)s ago"
        case 60..<3600: return "\(secs / 60)m ago"
        case 3600..<86400: return "\(secs / 3600)h ago"
        default: return "\(secs / 86400)d ago"
        }
    }
}

/// Generic envelope matching backend {ok, data} / {ok, error} shape.
/// Every /api/v1/* response decodes through this type.
nonisolated struct APIResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let data: T?
    let error: APIErrorPayload?

    enum CodingKeys: String, CodingKey {
        case ok, data, error
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decode(Bool.self, forKey: .ok)
        data = try container.decodeIfPresent(T.self, forKey: .data)
        error = try container.decodeIfPresent(APIErrorPayload.self, forKey: .error)
    }
}

nonisolated struct APIErrorPayload: Decodable {
    let code: String
    let message: String

    enum CodingKeys: String, CodingKey {
        case code, message
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
    }
}

// MARK: - Paginated responses

public nonisolated struct ListingsResponse: Decodable , Sendable {
    public let items: [Listing]
    public let total: Int
    let limit: Int
    let offset: Int
    let filtered: Bool?
}

public nonisolated struct NotificationsResponse: Decodable , Sendable {
    public let items: [NotificationItem]
    public let total: Int
    let unread: Int
    let limit: Int
    let offset: Int
}

// MARK: - Me endpoints

public nonisolated struct MeSummary: Decodable , Sendable {
    public let role: String
    let totalInDb: Int
    let new24hTotal: Int
    public let matchedTotal: Int
    let matchedAvailable: Int?

    /// 契约里 `last_scrape` 在 `required` 里，但类型是 `["string", "null"]`
    /// ——一次都还没抓过时后端发的就是 `null`。非可选 `String` 会在那一刻
    /// `valueNotFound` 掉整个 `/me/summary`，仪表盘和登录页的"上次更新"
    /// 一起变成连接失败。空串兜底：`DashboardView` / `LoginView` 已经在
    /// 用 `.isEmpty` 和 `?? ""` 走"没有时间戳"那支。
    public let lastScrape: String
    public let filterActive: Bool

    public enum CodingKeys: String, CodingKey {
        case role
        case totalInDb = "total_in_db"
        case new24hTotal = "new_24h_total"
        case matchedTotal = "matched_total"
        case matchedAvailable = "matched_available"
        case lastScrape = "last_scrape"
        case filterActive = "filter_active"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        totalInDb = try c.decode(Int.self, forKey: .totalInDb)
        new24hTotal = try c.decode(Int.self, forKey: .new24hTotal)
        matchedTotal = try c.decode(Int.self, forKey: .matchedTotal)
        matchedAvailable = try c.decodeIfPresent(Int.self, forKey: .matchedAvailable)
        lastScrape = try c.decodeIfPresent(String.self, forKey: .lastScrape) ?? ""
        filterActive = try c.decode(Bool.self, forKey: .filterActive)
    }
}

public nonisolated struct MeFilterResponse: Decodable , Sendable {
    let role: String
    public let filter: ListingFilter
    let isEmpty: Bool

    public enum CodingKeys: String, CodingKey {
        case role, filter
        case isEmpty = "is_empty"
    }
}

// MARK: - Mark read

public nonisolated struct MarkReadResponse: Decodable , Sendable {
    let marked: Bool
}

// MARK: - Devices / APNs (Phase 3)

/// `POST /api/v1/devices/register` 请求体。
nonisolated struct DeviceRegisterRequest: Encodable {
    let deviceToken: String
    let env: String       // "sandbox" | "production"
    let platform: String  // "ios"
    let model: String     // 硬件标识符，如 "iPhone16,2"（不是 "iPhone"）
    let bundleId: String
    let language: String  // "en" | "zh" | ...
    let osVersion: String // "18.5"

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case env, platform, model
        case bundleId = "bundle_id"
        case language
        // 叫 os_version 而不是 ios_version：这个端点是跨平台的（platform 字段
        // 区分 ios / android），Android 那边报的是 Android 版本号。崩溃上报那条
        // 路径（APIClient.uploadCrashDiagnostic）用的是 ios_version，因为那个
        // 端点本来就只有 iOS 在打。两个名字不一致是有意的，别顺手统一。
        case osVersion = "os_version"
    }
}

nonisolated struct DeviceRegisterResponse: Decodable {
    let deviceId: Int
    let env: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case env, platform
    }
}

/// `/api/v1/devices` 列表返回；device_token 只回脱敏 hint，不会回明文。
nonisolated struct DeviceListResponse: Decodable {
    let items: [DeviceInfo]
}

/// 一台已注册的推送设备——契约里的 `Device`。
///
/// 契约的 `required` 只有 `id / device_token_hint / env / platform / disabled`。
/// 剩下四个键后端可以不发，`created_at` / `last_seen` 连类型都是
/// `["string", "null"]`。合成的 `Decodable` 会把它们当必填，缺一个就
/// `keyNotFound` → 整个 `items` 数组解不出来 → **设备列表整页打不开**，
/// 而不是少列一台设备。同 ``MapListing`` / ``CalendarListing`` 那两处。
///
/// 今天的后端（`app/services/device_service.list_devices_for_token_safe`）
/// 其实每个键都发，`model` / `disabled_reason` 也已经在 Python 侧
/// `or ""` 兜过底了。所以这不是在修一条正在崩的线，是把客户端收回到
/// **契约承诺的范围**——后端哪天照契约允许的样子少发一个键，不该由这里塌方。
nonisolated struct DeviceInfo: Decodable, Identifiable {

    /// 契约 required——缺了就该响。
    let id: Int
    let deviceTokenHint: String
    let env: String
    let platform: String
    let disabled: Bool

    /// 机型和停用原因：契约 optional。空串就是"不知道"，
    /// 和后端 Python 侧 `or ""` 的兜底口径一致。
    let model: String
    let disabledReason: String

    /// 时间戳用**可选**而不是空串。
    ///
    /// 契约把这两个写成 `["string", "null"]`，而 `""` 不是一个时间——拿它去
    /// `DateFormatter` 只会得到 nil，却没法和"解析失败"分开。可选逼调用方
    /// 明确处理"没有时间戳"这一支，也和包里既有的 ``Listing/firstSeen``、
    /// ``Listing/lastSeen`` 同一个形状。
    let createdAt: String?
    let lastSeen: String?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceTokenHint = "device_token_hint"
        case env, platform, model
        case createdAt = "created_at"
        case lastSeen = "last_seen"
        case disabled
        case disabledReason = "disabled_reason"
    }

    /// 手写而不用合成，理由见上面各属性的注释。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        deviceTokenHint = try c.decode(String.self, forKey: .deviceTokenHint)
        env = try c.decode(String.self, forKey: .env)
        platform = try c.decode(String.self, forKey: .platform)
        disabled = try c.decode(Bool.self, forKey: .disabled)

        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        disabledReason = try c.decodeIfPresent(String.self, forKey: .disabledReason) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeen)
    }
}

nonisolated struct DeviceDeleteResponse: Decodable {
    let deleted: Bool
}

/// `GET /api/v1/filter/options` 响应——FilterEditView 用来渲染所有多选项的候选。
///
/// **跨版本兼容**：自定义 `init(from:)` 让任一字段缺失都回退 `[]`。
/// 老 backend 没有 `sources` 字段（P1 多源新加）时 iOS 不会 data error。
public nonisolated struct FilterOptions: Decodable, Sendable {
    public let cities: [String]
    public let sources: [String]
    public let occupancy: [String]
    public let types: [String]
    public let neighborhoods: [String]
    public let contract: [String]
    public let tenant: [String]
    public let offer: [String]
    public let finishing: [String]
    public let energy: [String]

    /// 每个过滤维度实际生效于哪些平台，key 是**后端的维度名**
    /// （`contract` / `neighborhood` / `offer` / …），值是 source key 列表。
    ///
    /// 后端 `_SOURCE_FILTER_DIMS` 决定的是一件沉默的事：勾了 Contract 只会
    /// 影响 Holland2Stay，其余六个平台整条跳过。老 backend 不返回这个 key，
    /// 此时为空字典——界面退回不作标注，而不是标成"对所有平台生效"。
    public let dimSources: [String: [String]]

    public enum CodingKeys: String, CodingKey {
        case cities, sources, occupancy, types, neighborhoods
        case contract, tenant, offer, finishing, energy
        case dimSources = "dim_sources"
    }

    init(
        cities: [String], sources: [String], occupancy: [String],
        types: [String], neighborhoods: [String], contract: [String],
        tenant: [String], offer: [String], finishing: [String], energy: [String],
        dimSources: [String: [String]] = [:]
    ) {
        self.cities = cities; self.sources = sources; self.occupancy = occupancy
        self.types = types; self.neighborhoods = neighborhoods; self.contract = contract
        self.tenant = tenant; self.offer = offer; self.finishing = finishing; self.energy = energy
        self.dimSources = dimSources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cities        = try c.decodeIfPresent([String].self, forKey: .cities)        ?? []
        self.sources       = try c.decodeIfPresent([String].self, forKey: .sources)       ?? []
        self.occupancy     = try c.decodeIfPresent([String].self, forKey: .occupancy)     ?? []
        self.types         = try c.decodeIfPresent([String].self, forKey: .types)         ?? []
        self.neighborhoods = try c.decodeIfPresent([String].self, forKey: .neighborhoods) ?? []
        self.contract      = try c.decodeIfPresent([String].self, forKey: .contract)      ?? []
        self.tenant        = try c.decodeIfPresent([String].self, forKey: .tenant)        ?? []
        self.offer         = try c.decodeIfPresent([String].self, forKey: .offer)         ?? []
        self.finishing     = try c.decodeIfPresent([String].self, forKey: .finishing)     ?? []
        self.energy        = try c.decodeIfPresent([String].self, forKey: .energy)        ?? []
        self.dimSources    = try c.decodeIfPresent([String: [String]].self, forKey: .dimSources) ?? [:]
    }

    public static let empty = FilterOptions(
        cities: [], sources: [], occupancy: [], types: [], neighborhoods: [],
        contract: [], tenant: [], offer: [], finishing: [], energy: [])
}

/// `POST /api/v1/auth/verify` 响应。密码正确才会返回，错误走 401 抛错路径。
public nonisolated struct VerifyPasswordResponse: Decodable, Sendable {
    public let ok: Bool
}

/// `POST /api/v1/devices/test` 响应。
public nonisolated struct DeviceTestPushResponse: Decodable, Sendable {
    public let sent: Int
    public let total: Int
    public let results: [DeviceTestPushResult]
}

public nonisolated struct DeviceTestPushResult: Decodable, Identifiable, Sendable {
    public var id: String { deviceTokenHint }
    public let deviceTokenHint: String
    public let env: String
    public let status: Int
    public let reason: String
    public let ok: Bool

    enum CodingKeys: String, CodingKey {
        case deviceTokenHint = "device_token_hint"
        case env, status, reason, ok
    }
}

/// `DELETE /api/v1/me` 响应
public nonisolated struct AccountDeleteResponse: Decodable, Sendable {
    let deleted: Bool
    let userId: String

    enum CodingKeys: String, CodingKey {
        case deleted
        case userId = "user_id"
    }
}

/// `GET /api/v1/legal` 响应
public nonisolated struct LegalResponse: Decodable , Sendable {
    public let terms: String
    public let privacy: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case terms, privacy
        case updatedAt = "updated_at"
    }
}

/// `POST /api/v1/auth/password` 响应
public nonisolated struct ChangePasswordResponse: Decodable, Sendable {
    /// 改密码同时被撤销的"其他设备会话"数量；当前 token 不在内
    let revokedOtherSessions: Int

    enum CodingKeys: String, CodingKey {
        case revokedOtherSessions = "revoked_other_sessions"
    }
}
