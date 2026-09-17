import Foundation

/// 小组件那一格要显示的全部内容，一份值。
///
/// 为什么小组件**不自己去取数**
/// --------------------------
/// 扩展是另一个进程，它想自己发请求就得先拿到三样东西：bearer token、
/// 用户那台服务器的地址、以及「这个数套没套个人筛选」的口径。三样都要往外挪：
///
/// - token 只能走共享钥匙串组。而这个仓库刚因为 token 落到 `UserDefaults` 里
///   吃过一次静默的亏（见 ``KeychainManager`` 顶部那段），多一个进程碰它就多一处
///   要一起对的地方。
/// - 服务器地址在 app 自己的 `UserDefaults` 里（`server_url`）。扩展读到的是**它
///   自己那份**，于是自建实例的用户，小组件会去问 flatradar.app——不报错，只是
///   显示别人家的数字。
/// - 口径（`Matching filters` / `Listings`）是 app 那边一串判断的结果，抄一份到
///   扩展里就是第二个会漂的地方。而 docs/MACOS.md 对这件事只有一句要求：
///   **「文案和口径要一致」**。
///
/// 所以反过来：**app 算完，把结果整个放进共享容器，小组件只负责画。**
/// 口径不可能不一致——它根本没有第二份算法。代价只有一个，数据会旧，
/// 而那一条下面单独处理。
///
/// 放在包里而不是 Mac 那一侧，是因为 docs/NEXT.md 里 iOS 的主屏 / 锁屏小组件是同一
/// 件事的另一端；两端各写一份结构体和一份措辞，就正好是上面那句要求禁止的事。
public nonisolated struct WidgetSnapshot: Codable, Sendable, Equatable {

    /// 当前匹配数。服务端算好的 `total`，`nil` 表示这一次没取到（不是 0）。
    public var matchCount: Int?

    /// 这个数**套没套**用户的个人筛选。决定标题是 `Matching filters` 还是 `Listings`。
    public var isFiltered: Bool

    /// 后端最近一次扫描的时间戳，**原样存后端给的串**。
    ///
    /// 不在这里先算成 "4m ago" 再存：那个相对时间一写进文件就开始过期，而小组件
    /// 每次渲染都要按当时的时刻重算一遍。存原始时间戳，重算是 ``ServerTime`` 的事。
    public var lastScrape: String

    /// 今天的新增（`new_24h`）。中号那一格用，小号放不下。
    public var newToday: Int?

    /// 未读提醒。
    public var unreadAlerts: Int

    /// 未读那一行要不要出现。
    ///
    /// 访客没有个人通知流（docs/MACOS.md 风险 6），这个数永远是 0——摆一行
    /// 常驻的 `Unread 0` 只会让人以为坏了。菜单栏那一格是同样的判断。
    public var showsUnread: Bool

    /// 这份快照是**什么时候写的**。下面 ``footnote(at:)`` 全靠它。
    public var capturedAt: Date

    public init(matchCount: Int?,
                isFiltered: Bool,
                lastScrape: String,
                newToday: Int?,
                unreadAlerts: Int,
                showsUnread: Bool,
                capturedAt: Date) {
        self.matchCount = matchCount
        self.isFiltered = isFiltered
        self.lastScrape = lastScrape
        self.newToday = newToday
        self.unreadAlerts = unreadAlerts
        self.showsUnread = showsUnread
        self.capturedAt = capturedAt
    }

    // MARK: - 文案
    //
    // 这一节一个字符串字面量都没有——全部走 ``StatusWording``，菜单栏那一格读的
    // 是同一份。docs/MACOS.md 要求的「文案和口径要一致」因此不是一句承诺，
    // 而是两处调用同一个函数的结果。

    public var countLabel: String { StatusWording.countLabel(isFiltered: isFiltered) }

    public var countText: String { StatusWording.countText(matchCount) }

    // MARK: - 旧了怎么办

    /// 这份快照在多久之内还算「现在」。
    ///
    /// 这个数不是拍脑袋的，它**就是**我们愿意给「scanned X ago」注入的最大误差：
    /// 快照在 `capturedAt` 记下了后端那一刻的扫描时间，而小组件是拿**当前时刻**
    /// 去减它的。app 有多久没跑，这句话就偏悲观多少秒——一秒不差地相等。
    /// 定 10 分钟，就是说这句话最多把「刚扫完」说成「10 分钟前扫的」，
    /// 在人读起来还是同一个意思。
    public static let freshFor: TimeInterval = 10 * 60

    public func isFresh(at now: Date) -> Bool {
        now.timeIntervalSince(capturedAt) < Self.freshFor
    }

    /// 底下那行小字。**新鲜和过期说的不是同一句话。**
    ///
    /// 新鲜时说后端：`scanned 4m ago`。
    ///
    /// 过期之后改说我们自己：`checked 3d ago`。这一步是这段代码里最要紧的一条——
    /// 过期时如果还照直说 `scanned 3d ago`，读者看到的是**「这个服务三天没扫了」**，
    /// 而事实是「你这台 Mac 三天没开过 FlatRadar」。那不是"数据旧了"，
    /// 那是替后端背了一口它没犯的锅。我们手上真正知道的只有 `capturedAt`，
    /// 所以过期之后就只说这一件知道的事。
    ///
    /// 数字本身两种状态都照常显示（只是变浅）：匹配总数比扫描时刻稳得多，
    /// 配上「几时取的」仍然是有用的信息，而一格只会说「请打开 app」的小组件
    /// 没有存在的理由。
    public func footnote(at now: Date) -> String {
        if isFresh(at: now), let scanned = scannedAgoText(at: now) {
            return StatusWording.scanned(scanned)
        }
        return "checked \(ServerTime.relativeTime(since: capturedAt, now: now))"
    }

    /// `4m ago`。和 ``SummaryModel/scannedAgoText`` 同一套判断：空串、`--`、
    /// 以及解析失败（`relativeTime` 会把原串原样退回来）都返回 nil，
    /// 由调用方省略整句，而不是显示一个 "scanned unknown"。
    public func scannedAgoText(at now: Date) -> String? {
        guard !lastScrape.isEmpty, lastScrape != "--" else { return nil }
        let text = ServerTime.relativeTime(lastScrape, now: now)
        return text == lastScrape ? nil : text
    }

    // MARK: - 时间轴

    /// 从 `now` 起，接下来该在哪些时刻重新渲染这一格。
    ///
    /// 小组件的文字会自己变旧（`4m ago` → `5m ago` → …），而 WidgetKit 不会替你
    /// 重画——你得在时间轴里**把每一次该变的时刻都列出来**。间隔按 ``ServerTime``
    /// 的分档走：一小时内每分钟一跳（那一档的文字每分钟都在变），之后每小时一跳
    /// （`h` 档一小时才变一次，再密就是白烧配额）。
    ///
    /// 上限 24 小时。再往后那一格已经过期很久，`checked 2d ago` 和
    /// `checked 3d ago` 之间没有值得花一次刷新去更新的差别；而且 app 只要跑一次
    /// 就会主动踢一次时间轴，真正的复活走的是那条路。
    public func refreshPoints(from now: Date) -> [Date] {
        var points: [Date] = [now]
        for minute in 1..<60 {
            points.append(now.addingTimeInterval(TimeInterval(minute * 60)))
        }
        for hour in 1...24 {
            points.append(now.addingTimeInterval(TimeInterval(hour * 3600)))
        }
        return points
    }

    // MARK: - 变没变

    /// 数字有没有变——**不含 `capturedAt`**。
    ///
    /// ``WidgetBridge/publish(_:)`` 用它决定要不要真去踢一次时间轴。每刷新一次就
    /// 踢一次的话，一个数都没动也会烧掉一次刷新配额，而那个配额是每天有限的。
    public func sameNumbers(as other: WidgetSnapshot) -> Bool {
        matchCount == other.matchCount
            && isFiltered == other.isFiltered
            && lastScrape == other.lastScrape
            && newToday == other.newToday
            && unreadAlerts == other.unreadAlerts
            && showsUnread == other.showsUnread
    }

    /// 没有任何数据时的样子。小组件在图库里预览、以及还没登录时用它。
    public static func placeholder(at now: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshot(matchCount: nil, isFiltered: false, lastScrape: "",
                       newToday: nil, unreadAlerts: 0, showsUnread: false,
                       capturedAt: now)
    }
}
