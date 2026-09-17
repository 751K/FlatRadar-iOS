import XCTest
@testable import FlatRadarCore

/// 桌面小组件那一格要守住的东西。
///
/// 这里一条都不碰文件系统——``WidgetBridge`` 那一半（App Group 容器真的连不连
/// 得上）在 `FlatRadarMacTests/WidgetBridgeTests.swift`，它得跑在带 entitlement
/// 的宿主 app 里。这个文件测的是**说什么**和**什么时候改口**。
final class WidgetSnapshotTests: XCTestCase {

    /// 4 分钟前扫的，刚取的快照。
    private func snapshot(scrapedSecondsAgo: Double = 240,
                          capturedAt: Date,
                          matchCount: Int? = 193,
                          isFiltered: Bool = true) -> WidgetSnapshot {
        WidgetSnapshot(
            newToday: 12,
            dailyNew: [10, 12, 14, 11, 12],
            totalListings: 892,
            statusChanges: 47,
            matchCount: matchCount,
            isFiltered: isFiltered,
            unreadAlerts: 3,
            showsUnread: true,
            lastScrape: capturedAt.addingTimeInterval(-scrapedSecondsAgo).ISO8601Format(),
            capturedAt: capturedAt)
    }

    // MARK: - 文案和菜单栏是同一份

    /// 小组件和菜单栏读的是同一个函数，不是两份长得一样的字面量。
    ///
    /// 这条会在有人把 `WidgetSnapshot.countLabel` 改回内联字面量时失败——
    /// 那正是 docs/MACOS.md「文案和口径要一致」被绕过的那一刻。
    func test_口径走共用的那一份() {
        let now = Date()
        XCTAssertEqual(snapshot(capturedAt: now, isFiltered: true).countLabel,
                       StatusWording.countLabel(isFiltered: true))
        XCTAssertEqual(snapshot(capturedAt: now, isFiltered: false).countLabel,
                       StatusWording.countLabel(isFiltered: false))
    }

    /// 字面量本身也钉一次：上面那条只保证"两处相同"，改成两处一起错它照样过。
    func test_两句话就是这两句() {
        XCTAssertEqual(StatusWording.countLabel(isFiltered: true), "Matching filters")
        XCTAssertEqual(StatusWording.countLabel(isFiltered: false), "Listings")
    }

    /// 拿不到匹配数显示 `—`，**不是 0**。
    ///
    /// 0 是「一套都没匹配上」，是个结论；拿不到不是结论。屏幕上一个大大的 0
    /// 会被当成前者读。
    func test_拿不到匹配数不显示成零() {
        XCTAssertEqual(snapshot(capturedAt: Date(), matchCount: nil).countText, "—")
        XCTAssertEqual(snapshot(capturedAt: Date(), matchCount: 0).countText, "0")
    }

    // MARK: - 旧了就改口（这个文件里最要紧的一条）

    /// 新鲜时说**后端**什么时候扫的。
    func test_新鲜时说的是后端() {
        let captured = Date()
        let snap = snapshot(scrapedSecondsAgo: 240, capturedAt: captured)
        // 快照取回来 1 分钟之后看：后端那次扫描现在是 5 分钟前。
        XCTAssertEqual(snap.footnote(at: captured.addingTimeInterval(60)), "scanned 5m ago")
    }

    /// 过期之后**改说自己**，而且绝不再提 scanned。
    ///
    /// 这是整个小组件里最容易做错、做错了也最难发现的一条。照直说
    /// `scanned 3d ago` 的话，读者看到的是「这个服务三天没扫了」——而事实是
    /// 「你这台 Mac 三天没开过 FlatRadar」。那不是"数据旧了"，那是替后端
    /// 背了一口它没犯的锅，而且锅就摆在桌面上。
    func test_过期之后不再替后端说话() {
        let captured = Date()
        let snap = snapshot(scrapedSecondsAgo: 240, capturedAt: captured)
        let line = snap.footnote(at: captured.addingTimeInterval(3 * 24 * 3600))
        XCTAssertEqual(line, "checked 3d ago")
        XCTAssertFalse(line.contains("scanned"),
                       "过期之后还在说 scanned，就是在替后端认一件它没做的事")
    }

    /// 阈值**就是**我们愿意给「scanned X ago」注入的最大误差：
    /// app 多久没跑，那句话就偏悲观多少秒，一秒不差。所以它不是一个随手定的数，
    /// 改它等于改「这句话最多可以错多少」。
    func test_新鲜的边界就在那个误差上() {
        let captured = Date()
        let snap = snapshot(capturedAt: captured)
        XCTAssertTrue(snap.isFresh(at: captured.addingTimeInterval(WidgetSnapshot.freshFor - 1)))
        XCTAssertFalse(snap.isFresh(at: captured.addingTimeInterval(WidgetSnapshot.freshFor)))
    }

    /// 扫描时间解析不出来时，新鲜也不硬说。
    ///
    /// `ServerTime.relativeTime` 解析失败会把原串原样退回来，直接拼上去就是
    /// `scanned 2026-13-45T99:99`。这条钉住那种情况下退回「几时取的」。
    func test_扫描时间读不懂就不说扫描时间() {
        let captured = Date()
        var snap = snapshot(capturedAt: captured)
        snap.lastScrape = "不是一个时间戳"
        XCTAssertNil(snap.scannedAgoText(at: captured))
        XCTAssertEqual(snap.footnote(at: captured), "checked 0s ago")

        snap.lastScrape = ""
        XCTAssertNil(snap.scannedAgoText(at: captured))
        snap.lastScrape = "--"
        XCTAssertNil(snap.scannedAgoText(at: captured))
    }

    // MARK: - 时间轴

    /// 这一格的文字自己会变旧，而 WidgetKit 不会主动重画——每一次该变的时刻
    /// 都得列进时间轴。分档跟着 ``ServerTime``：一小时内每分钟一跳，之后每小时。
    func test_时间轴按相对时间的分档给点() {
        let now = Date()
        let points = WidgetSnapshot.placeholder(at: now).refreshPoints(from: now)

        XCTAssertEqual(points.first, now, "第一个条目必须是现在，否则刚摆上去是空的")
        XCTAssertEqual(points.count, 1 + 59 + 24)
        XCTAssertEqual(zip(points, points.dropFirst()).filter { $0 >= $1 }.count, 0,
                       "时间轴必须严格递增")

        // 头一个小时：每分钟一跳，正好覆盖 `Xm ago` 每分钟都在变的那一档。
        XCTAssertEqual(points[1].timeIntervalSince(now), 60, accuracy: 0.001)
        XCTAssertEqual(points[59].timeIntervalSince(now), 59 * 60, accuracy: 0.001)
        // 之后每小时一跳：`Xh ago` 一小时才变一次，再密就是白烧刷新配额。
        XCTAssertEqual(points[60].timeIntervalSince(now), 3600, accuracy: 0.001)
        XCTAssertEqual(points.last?.timeIntervalSince(now), 24 * 3600)
    }

    // MARK: - 存取

    func test_编码解码原样往返() throws {
        let snap = snapshot(capturedAt: Date())
        let back = try JSONDecoder().decode(
            WidgetSnapshot.self, from: try JSONEncoder().encode(snap))
        XCTAssertEqual(back, snap)
    }

    /// `sameNumbers` 不看采集时间——``WidgetBridge/publish(_:)`` 用它决定
    /// 要不要花掉一次刷新配额，而「只是又取了一次、数字一个没变」正是最常见的调用。
    func test_只有采集时间变了不算变() {
        let captured = Date()
        let a = snapshot(scrapedSecondsAgo: 240, capturedAt: captured)
        var b = a
        b.capturedAt = captured.addingTimeInterval(600)
        XCTAssertTrue(a.sameNumbers(as: b))

        b.unreadAlerts += 1
        XCTAssertFalse(a.sameNumbers(as: b), "未读数变了要重画")
    }
}

/// ``ServerTime/relativeTime(_:now:)`` 的四个分档。
///
/// 原来那版把 `Date()` 焊死在函数体里，除了 `0s ago` 之外**一档都没法断言**——
/// 小组件要求把「现在」传进来，顺带让这四档第一次能被测。
final class RelativeTimeBucketTests: XCTestCase {

    private func ago(_ seconds: TimeInterval) -> String {
        let now = Date()
        return ServerTime.relativeTime(now.addingTimeInterval(-seconds).ISO8601Format(), now: now)
    }

    func test_四个分档() {
        XCTAssertEqual(ago(0), "0s ago")
        XCTAssertEqual(ago(59), "59s ago")
        XCTAssertEqual(ago(60), "1m ago")
        XCTAssertEqual(ago(3599), "59m ago")
        XCTAssertEqual(ago(3600), "1h ago")
        XCTAssertEqual(ago(86_399), "23h ago")
        XCTAssertEqual(ago(86_400), "1d ago")
    }

    /// 服务端时间比本机略超前时差值是负的，不挡就会显示 `-3s ago`。
    func test_时钟超前不显示负数() {
        XCTAssertEqual(ago(-30), "0s ago")
    }

    /// `Date` 那一版和字符串那一版共用同一套分档，所以两句话的措辞不会漂。
    func test_Date_那一版和字符串那一版分档相同() {
        let now = Date()
        for seconds in [0.0, 59, 60, 3599, 3600, 86_400] {
            let point = now.addingTimeInterval(-seconds)
            XCTAssertEqual(ServerTime.relativeTime(since: point, now: now),
                           ServerTime.relativeTime(point.ISO8601Format(), now: now),
                           "\(seconds) 秒这一档两版对不上")
        }
    }
}

/// 日历那一格的数据：从后端按日分好的组，切成一段连续的序列。
final class MoveInDayTests: XCTestCase {

    /// `CalendarListing` 只有 `init(from decoder:)`，所以造数据就顺便走一遍解码。
    private func listing(_ id: String, status: String, day: String) throws -> CalendarListing {
        let json = """
        {"id":"\(id)","name":"n","status":"\(status)","available_from":"\(day)"}
        """
        return try JSONDecoder().decode(CalendarListing.self, from: Data(json.utf8))
    }

    private func day(_ offset: Int, from start: Date) -> String {
        MoveInDay.dayKey(ServerTime.calendar.date(byAdding: .day, value: offset, to: start)!)
    }

    /// 序列必须**连续**，空着的日子也占一格。
    ///
    /// 只给有货的日子会把时间轴压缩成一排等距的柱子——"隔了两周才有下一批"
    /// 和"明天就有"会画成一模一样的图。
    func test_序列连续而且空日子也在() throws {
        let start = ServerTime.calendar.startOfDay(for: Date())
        let grouped = [day(2, from: start): [try listing("a", status: "book", day: day(2, from: start))]]

        let series = MoveInDay.series(listingsByDay: grouped, from: start, days: 5)

        XCTAssertEqual(series.count, 5)
        XCTAssertEqual(series.map(\.day), (0..<5).map { day($0, from: start) })
        XCTAssertEqual(series.map(\.total), [0, 0, 1, 0, 0])
    }

    /// `bookable` 的口径和 `CalendarPane.actionable` 一字不差：可订 + 抽签。
    ///
    /// 这是这一格里最容易做错的一条。实测 691 条里 609 条是 Occupied——
    /// 它们的 `available_from` 是未来的**退租日**。把它们算进"能抢的"，
    /// 一个数会差一个数量级。
    func test_只有可订和抽签算能抢的() throws {
        let start = ServerTime.calendar.startOfDay(for: Date())
        let key = day(0, from: start)
        let grouped = [key: [
            try listing("1", status: "book", day: key),
            try listing("2", status: "lottery", day: key),
            try listing("3", status: "occupied", day: key),
            try listing("4", status: "reserved", day: key),
            try listing("5", status: "not_available", day: key),
        ]]

        let series = MoveInDay.series(listingsByDay: grouped, from: start, days: 1)

        XCTAssertEqual(series[0].total, 5)
        XCTAssertEqual(series[0].bookable, 2,
                       "只有 book + lottery 算。把 occupied 算进来的话，"
                       + "「这天 5 套可抢」会被照着信，而实际只有 2 套。")
    }

    /// 「下一个能抢的日子」跳过只有退租日的那些天。
    ///
    /// 找 `total > 0` 的第一个命中多半是一堆 Occupied，点进去什么也做不了——
    /// 那种"下一个"是假的。
    func test_下一个能抢的日子跳过只有退租的那几天() {
        let series = [
            MoveInDay(day: "2026-09-17", total: 0, bookable: 0),
            MoveInDay(day: "2026-09-18", total: 12, bookable: 0),   // 全是退租
            MoveInDay(day: "2026-09-19", total: 3, bookable: 1),
        ]
        XCTAssertEqual(MoveInDay.nextBookable(in: series)?.day, "2026-09-19")
    }

    func test_一套能抢的都没有时返回_nil() {
        let series = [MoveInDay(day: "2026-09-17", total: 40, bookable: 0)]
        XCTAssertNil(MoveInDay.nextBookable(in: series))
    }
}

/// 「今天比平时多还是少」那一对数。统计带和小组件共用，所以它们不可能对不上。
final class DailyNewTests: XCTestCase {

    /// 基准**不含今天**：拿今天去和含今天的均值比，今天自己会把基准抬上去，
    /// 涨幅被系统性压小。
    func test_基准排除今天() {
        // 过去四天 10/10/10/10，今天 30。
        XCTAssertEqual(DailyNew.baselineAverage([10, 10, 10, 10, 30]), 10)
        XCTAssertEqual(DailyNew.changeVsBaseline(today: 30, series: [10, 10, 10, 10, 30]), 200)
    }

    /// 样本不足 3 天不给比较——宁可不显示，也不显示一个没有意义的百分比。
    func test_样本太少不给基准() {
        XCTAssertNil(DailyNew.baselineAverage([10, 20, 30]))      // 去掉今天只剩 2
        XCTAssertNotNil(DailyNew.baselineAverage([10, 20, 30, 40]))
    }

    /// 基准是 0 时不给百分比：除以零得不到有意义的数，而「从 0 涨到 5」
    /// 写成 `+500%` 是在编。
    func test_基准为零不给百分比() {
        XCTAssertNil(DailyNew.changeVsBaseline(today: 5, series: [0, 0, 0, 5]))
    }
}

/// 换版本时磁盘上躺着的是上一版写的 JSON。
final class SnapshotCompatibilityTests: XCTestCase {

    /// 缺字段一律退默认值，**不抛错**。
    ///
    /// 合成的 `Decodable` 少一个键就整份解不出来，于是升级之后桌面上那两格会
    /// 空着，直到 app 下一次跑起来重写——而"下一次跑起来"可能是几天后。
    /// 和 ``MonitorStatus`` 那份宽容解码同一个理由。
    func test_旧版本写的_JSON_还读得出来() throws {
        // 第一版只有这几个字段。
        let old = """
        {"matchCount":193,"isFiltered":true,"lastScrape":"","newToday":12,
         "unreadAlerts":3,"showsUnread":true,"capturedAt":780000000}
        """
        let snap = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(old.utf8))

        XCTAssertEqual(snap.matchCount, 193)
        XCTAssertEqual(snap.newToday, 12)
        XCTAssertEqual(snap.dailyNew, [], "新加的字段该退到默认值，而不是让整份解码失败")
        XCTAssertEqual(snap.moveIns, [])
        XCTAssertNil(snap.totalListings)
    }

    /// 唯一不能缺的是采集时间：没有它就判断不了新鲜度，
    /// 而「旧了要改口」是这份数据最要紧的一条规矩。
    func test_缺采集时间就该解码失败() {
        let bad = #"{"matchCount":1}"#
        XCTAssertThrowsError(try JSONDecoder().decode(WidgetSnapshot.self, from: Data(bad.utf8)))
    }

    /// `sameNumbers` 是拿"把两边采集时间抹平后比 `==`"实现的，所以**新加字段
    /// 自动被覆盖**——这条钉住那个性质，免得有人改回逐字段罗列然后漏掉一个。
    func test_新字段也算在变没变里() {
        let now = Date()
        let a = WidgetSnapshot(moveIns: [MoveInDay(day: "2026-09-17", total: 1, bookable: 1)],
                               capturedAt: now)
        var b = a
        b.capturedAt = now.addingTimeInterval(600)
        XCTAssertTrue(a.sameNumbers(as: b))

        b.moveIns = []
        XCTAssertFalse(a.sameNumbers(as: b))

        var c = a
        c.dailyNew = [1]
        XCTAssertFalse(a.sameNumbers(as: c))
    }
}
