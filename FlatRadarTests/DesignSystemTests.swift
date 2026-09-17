import SwiftUI
import UIKit
import XCTest
@testable import FlatRadar
@testable import FlatRadarCore

/// 2026-09-17 那一轮「按设计规范体检」要守住的东西。
///
/// 三件事，共同点是**跑一遍界面看不出来**：
///
/// 1. **徽标和小字的对比度。** 真机审计在六屏上量到 98 条不达标，全是「同一个色
///    既当字又当底」或者「彩色小字写在白底上」。修法是把颜色压暗一档
///    （``Color/onTint(in:)`` / ``Color/onSurface(in:)``），而那两个混合比例是
///    算出来的——算错了界面照样能跑，只是继续看不清。这里把比例重新算一遍。
/// 2. **窄窗口 iPad 上的返回落点。** 原来按 `idiom == .pad` 分支，于是 iPad 竖屏
///    （834pt < 920，走的是窄窗口形态）从日历点进详情、返回时人落在列表里。
/// 3. **租客类别缩写撞名。** 两个不同的后端类别都被缩成 "Student"，卡上两行同名
///    不同数，读的人没法分辨。
///
/// `@MainActor` 标在**类**上：这个 target 没开 `SWIFT_DEFAULT_ACTOR_ISOLATION`
/// （那条只加在 app target 上），而它碰的 `NavigationCoordinator`、`UIColor`、
/// `DashboardView` 全是主 actor 隔离的。逐个方法标会漏，标一次全消。
@MainActor
final class DesignSystemTests: XCTestCase {

    // MARK: - 对比度

    /// WCAG 的相对亮度。公式照抄 W3C，不是近似。
    private func luminance(_ c: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func f(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
    }

    private func ratio(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 把 SwiftUI 的 `Color` 在指定明暗下解析成实际像素色。
    private func resolved(_ c: Color, _ style: UIUserInterfaceStyle) -> UIColor {
        UIColor(c).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
    }

    /// `fg` 以 `alpha` 的不透明度叠在 `bg` 上之后的实际颜色。
    /// 徽标的底就是这么来的：同色 13–16% 叠在卡片底上。
    private func composite(_ fg: UIColor, over bg: UIColor, alpha: CGFloat) -> UIColor {
        var fr: CGFloat = 0, fg_: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var br: CGFloat = 0, bg_: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        fg.getRed(&fr, green: &fg_, blue: &fb, alpha: &fa)
        bg.getRed(&br, green: &bg_, blue: &bb, alpha: &ba)
        return UIColor(red: fr * alpha + br * (1 - alpha),
                       green: fg_ * alpha + bg_ * (1 - alpha),
                       blue: fb * alpha + bb * (1 - alpha),
                       alpha: 1)
    }

    /// 全 App 会被当成「字色」用的那一批色。
    ///
    /// 平台色和状态色都在里面：新增一个平台或一档状态时，这条测试会替你把它
    /// 也量一遍——而这正是最容易漏的地方（`Platform.color` 上一次加四个平台时，
    /// 四个全落到了默认的蓝色）。
    private var inkCandidates: [(String, Color)] {
        Platform.knownKeys.map { ($0, Platform.color($0)) }
        + [("statusBook", .statusBook), ("statusLottery", .statusLottery),
           ("statusReserved", .statusReserved), ("statusOccupied", .statusOccupied),
           ("statusUnknown", .statusUnknown), ("accent", .accentColor)]
    }

    private static let aa: CGFloat = 4.5

    /// 徽标：字写在**自己 16% 的淡底**上。压暗之后每一个都要过 4.5:1。
    func test_徽标字色在淡底上过_AA() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let surface = resolved(Color(.secondarySystemGroupedBackground), style)
            for (name, color) in inkCandidates {
                let base = resolved(color, style)
                let tint = composite(base, over: surface, alpha: 0.16)
                let ink = resolved(color.onTint(in: style == .dark ? .dark : .light), style)
                let r = ratio(ink, tint)
                XCTAssertGreaterThanOrEqual(
                    r, Self.aa,
                    "\(name) 在 \(style == .dark ? "深色" : "浅色")下只有 "
                    + String(format: "%.2f", r) + ":1——徽标是 11–12pt 的文字，"
                    + "门槛 4.5。改了 Color.onTint 的混合比例就会踩这条。")
            }
        }
    }

    /// 普通背景上的小字（Explore 卡里的数字、日历的状态行、地图图例）。
    func test_彩色小字在普通底上过_AA() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            // 浅色下最白的那档底是 systemBackground，深色下最深的也是它。
            let surface = resolved(Color(.systemBackground), style)
            for (name, color) in inkCandidates {
                let ink = resolved(color.onSurface(in: style == .dark ? .dark : .light), style)
                let r = ratio(ink, surface)
                XCTAssertGreaterThanOrEqual(
                    r, Self.aa,
                    "\(name) 在 \(style == .dark ? "深色" : "浅色")下只有 "
                    + String(format: "%.2f", r) + ":1。")
            }
        }
    }

    /// 反过来钉一次：**不压暗**的原色确实是不够的。
    ///
    /// 没有这条，上面两条会在「`onTint` 改成直接 return self」时依然可能碰巧通过
    /// 某几个色——这条保证那种改法一定会红，也顺便记录了修之前的实际状况。
    func test_原色直接当字用确实不够() throws {
        let surface = resolved(Color(.systemBackground), .light)
        let failing = inkCandidates.filter { ratio(resolved($0.1, .light), surface) < Self.aa }
        XCTAssertFalse(
            failing.isEmpty,
            "如果每个原色本来就过 4.5:1，那 onTint / onSurface 这两个换算就是多余的，"
            + "应该删掉而不是留着。")
    }

    // MARK: - 窄窗口 iPad 的返回落点

    /// 窄窗口：三个视图共用 Browse 那一个栈，所以往栈上推一层，
    /// **不能动 `selectedBrowseMode`**——动了就等于把人脚下那一屏换掉。
    func test_窄窗口从日历点进详情不会换掉当前模式() {
        let coord = NavigationCoordinator()
        coord.usesCompactTabs = true
        coord.selectedTab = .browse
        coord.selectedBrowseMode = .calendar

        coord.showListing(id: "abc123", titleHint: "Laagstraat 404D")

        XCTAssertEqual(coord.selectedBrowseMode, .calendar,
                       "返回时应该回到日历。这正是原先 `idiom == .pad` 分支在 iPad "
                       + "竖屏上做错的事：它把模式改成了 .list。")
        XCTAssertEqual(coord.listingsPath.count, 1)
    }

    /// 宽窗口：Map / Calendar 各是独立 tab，详情压在**它自己那一栈**上，
    /// 返回就回到人来时的那一屏。
    func test_宽窗口从日历点进详情留在日历那一栈() {
        let coord = NavigationCoordinator()
        coord.usesCompactTabs = false
        coord.selectedTab = .calendar

        coord.showListing(id: "abc123")

        XCTAssertEqual(coord.selectedTab, .calendar, "不该被换到 Listings 去。")
        XCTAssertEqual(coord.calendarPath.count, 1)
        XCTAssertTrue(coord.listingsPath.isEmpty)
    }

    func test_宽窗口从地图点进详情留在地图那一栈() {
        let coord = NavigationCoordinator()
        coord.usesCompactTabs = false
        coord.selectedTab = .map

        coord.showListing(id: "abc123")

        XCTAssertEqual(coord.selectedTab, .map)
        XCTAssertEqual(coord.mapPath.count, 1)
        XCTAssertTrue(coord.listingsPath.isEmpty)
    }

    /// 「在地图上查看」要把**两种形态**的栈都清掉，否则详情页还盖在地图上。
    func test_openMap_两条栈都清() {
        let coord = NavigationCoordinator()
        coord.usesCompactTabs = false
        coord.selectedTab = .map
        coord.showListing(id: "abc123")
        coord.listingsPath = [.byId("zzz", titleHint: nil)]

        coord.openMap(focusing: "abc123")

        XCTAssertTrue(coord.mapPath.isEmpty)
        XCTAssertTrue(coord.listingsPath.isEmpty)
    }

    /// 登出要把新加的那两条栈也清掉——里面同样残留房源 id。
    func test_reset_清掉每一条导航栈() {
        let coord = NavigationCoordinator()
        coord.listingsPath = [.byId("a", titleHint: nil)]
        coord.mapPath = [.byId("b", titleHint: nil)]
        coord.calendarPath = [.byId("c", titleHint: nil)]

        coord.reset()

        XCTAssertTrue(coord.listingsPath.isEmpty)
        XCTAssertTrue(coord.mapPath.isEmpty)
        XCTAssertTrue(coord.calendarPath.isEmpty)
    }

    /// id 校验不能因为换了入口就丢掉。
    func test_showListing_也挡非法_id() {
        let coord = NavigationCoordinator()
        coord.usesCompactTabs = true
        coord.showListing(id: "../../etc/passwd")
        XCTAssertTrue(coord.listingsPath.isEmpty)
    }

    /// 默认值必须是「窄」。猜窄最坏是多一次返回，猜宽会把人甩到别的屏去。
    func test_形态默认按窄窗口算() {
        XCTAssertTrue(NavigationCoordinator().usesCompactTabs)
    }

    // MARK: - 租客类别缩写

    func test_两个类别缩成同一个词时退回原文() {
        let entries = [ChartEntry(label: "Students only", count: 193),
                       ChartEntry(label: "Working", count: 100),
                       ChartEntry(label: "Student (sharing)", count: 15)]
        let shown = entries.map { DashboardView.tenantMiniLabel($0.label, within: entries) }

        XCTAssertEqual(Set(shown).count, entries.count,
                       "卡上出现了两行同名不同数：\(shown)。真机上就是 "
                       + "`Student 193` / `Student 15`，读的人没法分辨。")
        XCTAssertEqual(shown[1], "Working", "没撞名的那个还是要缩。")
    }

    func test_不撞名时照常缩写() {
        let entries = [ChartEntry(label: "Students only", count: 193),
                       ChartEntry(label: "Working professionals", count: 100)]
        let shown = entries.map { DashboardView.tenantMiniLabel($0.label, within: entries) }
        XCTAssertEqual(shown, ["Student", "Working"])
    }
}
