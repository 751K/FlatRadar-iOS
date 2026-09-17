import XCTest
import FlatRadarCore
@testable import FlatRadarMac

/// Help 菜单那条「Contact Support…」拼出来的 `mailto:`。
///
/// 为什么值得一条测试
/// ------------------
/// 这条菜单项是用来**替掉一个死项**的（默认的 `FlatRadarMac Help` 点了只弹
/// 「帮助不可用」，因为这个 app 没有 help book）。替上来的东西要是也点不动，
/// 就白换了一次。
///
/// 具体的风险是 `URLComponents` 拼 `mailto:` 时**很容易把地址放错字段**：
/// 写成 `c.host = "support@flatradar.app"` 出来的是
/// `mailto://support@flatradar.app`——多出来的两个斜杠让它不再是一个合法的
/// mailto，邮件客户端不认，而代码读起来一模一样。
///
/// ⚠️ 这里**不测转义**。一度写过一条断言空格和 em dash 变成 `%20` / `%E2%80%94`，
/// 变异验证时发现它根本分不出手拼和 `URLComponents`：这个工具链上
/// `URL(string:)` 自己就会转义，两种写法产出同一个串。那条断言测的是
/// Foundation 的行为，不是我们的逻辑，删了。
final class SupportMailTests: XCTestCase {

    func test_是一个合法的_mailto_URL() {
        XCTAssertNotNil(FlatRadarMacApp.supportMailURL,
                        "拼不出 URL，菜单项就是个哑的——和它替掉的那条一样")
    }

    func test_收件人是条款里那个地址() throws {
        // 地址在两处出现（这里和 `LegalText`）就有漂移的可能。这条至少保证
        // 改到只剩一处时不会静悄悄改错。
        let url = try XCTUnwrap(FlatRadarMacApp.supportMailURL)
        XCTAssertEqual(url.scheme, "mailto")
        XCTAssertEqual(url.path, "support@flatradar.app")
    }

    func test_不是_mailto_双斜杠那种写法() throws {
        // `c.host = ...` 而不是 `c.path = ...` 会拼出 `mailto://support@…`，
        // 邮件客户端不认。这一条是整组里唯一真正卡得住写错字段的。
        let url = try XCTUnwrap(FlatRadarMacApp.supportMailURL)
        XCTAssertFalse(url.absoluteString.hasPrefix("mailto://"),
                       "地址放进了 host 而不是 path")
        XCTAssertNil(url.host, "mailto 不该有 host")
    }

    // `@MainActor`：包开了默认 MainActor 隔离，`AppVersion.short` 跟着被隔离，
    // 而测试 target 没开——不标的话编译期就拦下来。
    @MainActor
    func test_主题里带版本号() throws {
        // Mac 和 iOS 的版本号是分开的（1.0.0 vs 2.2.0），只写 "FlatRadar"
        // 收信的人看不出是哪一端，要多问一轮。
        let url = try XCTUnwrap(FlatRadarMacApp.supportMailURL)
        let subject = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "subject" }?.value
        XCTAssertEqual(subject, "FlatRadar for Mac \(AppVersion.short) — Support")
        XCTAssertTrue(subject?.contains("Mac") == true)
    }
}
