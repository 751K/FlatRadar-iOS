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
            matchCount: matchCount,
            isFiltered: isFiltered,
            lastScrape: capturedAt.addingTimeInterval(-scrapedSecondsAgo).ISO8601Format(),
            newToday: 12,
            unreadAlerts: 3,
            showsUnread: true,
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
