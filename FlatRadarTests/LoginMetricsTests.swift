import XCTest
@testable import FlatRadar

/// 登录屏三套布局的挑选规则。
///
/// 守的是什么
/// ----------
/// 头一版判据写的是 `width >= 600 && width > height`。iPhone 16 Pro 横过来是
/// **874×402**——宽度过线、而且 width > height，于是整屏走 iPad 横屏那套：
/// 左栏固定 560、插画 230、顶部留白 74，全塞进 402pt 高里。这个工程的 iPhone
/// 是允许横屏的（`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` 里有
/// LandscapeLeft/Right），所以不是理论问题。
///
/// 改成看**短边**之后这一类全归到 iPhone 那套。下面每条都是一个真实机型 /
/// 真实分屏档位的实际点阵尺寸，不是编的数。
final class LoginMetricsTests: XCTestCase {

    private func pick(_ w: CGFloat, _ h: CGFloat) -> LoginMetrics {
        LoginMetrics.forSize(CGSize(width: w, height: h))
    }

    // MARK: - iPhone

    func test_iPhone竖屏走手机那套() {
        for (w, h) in [(402.0, 874.0),   // 16 Pro
                       (393.0, 852.0),   // 15 / 16
                       (430.0, 932.0),   // 16 Pro Max
                       (375.0, 667.0)] { // SE
            let m = pick(w, h)
            XCTAssertFalse(m.splitsColumns, "\(w)×\(h)")
            XCTAssertNil(m.columnWidth, "\(w)×\(h)")
            XCTAssertFalse(m.showsPlatformCodes, "\(w)×\(h)")
        }
    }

    /// 回归用例本体。
    func test_iPhone横屏不能走iPad分栏() {
        for (w, h) in [(874.0, 402.0),   // 16 Pro
                       (932.0, 430.0),   // 16 Pro Max，短边最大的 iPhone
                       (852.0, 393.0)] {
            let m = pick(w, h)
            XCTAssertFalse(m.splitsColumns, "\(w)×\(h) 被判成了 iPad 横屏")
            XCTAssertEqual(m.skylineHeight, LoginMetrics.phone.skylineHeight, "\(w)×\(h)")
        }
    }

    // MARK: - iPad

    func test_iPad竖屏走居中列() {
        for (w, h) in [(834.0, 1194.0),  // 11 吋
                       (744.0, 1133.0),  // mini
                       (1024.0, 1366.0)] {
            let m = pick(w, h)
            XCTAssertFalse(m.splitsColumns, "\(w)×\(h)")
            XCTAssertEqual(m.columnWidth, 700, "\(w)×\(h)")
            XCTAssertTrue(m.cardsSideBySide, "\(w)×\(h)")
            XCTAssertTrue(m.showsPlatformCodes, "\(w)×\(h)")
        }
    }

    func test_iPad横屏走左右分栏() {
        for (w, h) in [(1194.0, 834.0), (1366.0, 1024.0)] {
            let m = pick(w, h)
            XCTAssertTrue(m.splitsColumns, "\(w)×\(h)")
            XCTAssertEqual(m.leftColumn, 560, "\(w)×\(h)")
            XCTAssertFalse(m.cardsSideBySide, "\(w)×\(h)")
            XCTAssertFalse(m.centersFooter, "\(w)×\(h)")
        }
    }

    /// iPad 分屏 / Slide Over 的窄栏该退回手机那套——700 的列在 507pt 里放不下。
    func test_iPad分屏窄栏退回手机那套() {
        for (w, h) in [(320.0, 834.0),   // Slide Over
                       (375.0, 1133.0),  // 1/3 竖屏
                       (507.0, 834.0),   // 11 吋 1/2
                       (570.0, 834.0)] { // 13 吋 1/2
            let m = pick(w, h)
            XCTAssertFalse(m.splitsColumns, "\(w)×\(h)")
            XCTAssertNil(m.columnWidth, "\(w)×\(h)")
        }
    }

    // MARK: - 表本身

    /// 横屏那套是从竖屏那套改出来的，容易漏改。这几条钉住真正该不一样的地方。
    func test_横屏是在竖屏基础上改的但该变的都变了() {
        let p = LoginMetrics.padPortrait
        let l = LoginMetrics.padLandscape
        XCTAssertEqual(p.skylineHeight, l.skylineHeight, "两种 iPad 布局插画一样高")
        XCTAssertNotEqual(p.headline, l.headline)
        XCTAssertNil(l.headlineMaxWidth, "横屏左栏本来就只有 560，不需要再限宽")
        XCTAssertNil(l.columnWidth, "横屏不走居中列")
        XCTAssertTrue(l.showsPlatformCodes, "平台缩写两种 iPad 布局都有")
    }
}
