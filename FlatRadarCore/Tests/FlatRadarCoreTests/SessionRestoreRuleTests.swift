import XCTest
@testable import FlatRadarCore

/// 启动恢复会话失败时，「扔不扔 token」「什么时候再试」这三条规则。
///
/// 原先的问题：`restoreSession()` 的 `catch` 不分错误一律删 token，没网时打开
/// app 等于被永久登出。修法把判断抽成了纯函数，就是这里测的三个。
///
/// 为什么只测纯函数、不直接测 `restoreSession()`：它会读写钥匙串。在 Mac 的测试
/// 宿主里那就是签过名的真 app，跑一次会把开发机上真正在用的登录态删掉。
@MainActor
final class SessionRestoreRuleTests: XCTestCase {

    // MARK: - 扔不扔

    func test_只有服务器明确拒绝才扔掉会话() {
        XCTAssertTrue(AuthStore.shouldDiscardSession(after: APIError.unauthorized("expired")))
        XCTAssertTrue(AuthStore.shouldDiscardSession(after: APIError.forbidden("revoked")))
    }

    /// 这一组就是原来那个 bug：每一种都会被旧代码当成"token 过期"删掉。
    func test_没问到不等于被拒_这些都保留会话() {
        let keep: [(String, Error)] = [
            ("断网", APIError.network(URLError(.notConnectedToInternet))),
            ("超时", APIError.network(URLError(.timedOut))),
            ("DNS", APIError.network(URLError(.cannotFindHost))),
            ("后端 5xx（信封里的 server_error）", APIError.serverError("boom")),
            ("限流", APIError.rateLimited("slow down")),
            ("没信封的 502", APIError.badResponse(502)),
            ("不是 HTTP 响应", APIError.badResponse(0)),
            ("代理吐的 HTML 页", APIError.decoding(URLError(.cannotParseResponse))),
            ("请求被取消", CancellationError()),
            ("没包装过的 URLError", URLError(.networkConnectionLost)),
        ]
        for (name, error) in keep {
            XCTAssertFalse(AuthStore.shouldDiscardSession(after: error),
                           "「\(name)」不能删 token——token 可能完全有效，只是这次没问到")
        }
    }

    /// 和 `APIClient` 触发全局 401 自动登出用的是同一个谓词。两边要是判得不一样，
    /// 就会出现"启动时删了 token、运行中却不会自动登出"（或者反过来）的错位。
    func test_判据和全局_401_自动登出是同一个() {
        let all: [APIError] = [
            .unauthorized(""), .forbidden(""), .notFound(""), .validation(""),
            .conflict(""), .rateLimited(""), .serverError(""),
            .network(URLError(.timedOut)), .decoding(URLError(.cannotParseResponse)),
            .badResponse(401), .badResponse(500),
        ]
        for error in all {
            XCTAssertEqual(AuthStore.shouldDiscardSession(after: error), error.isAuthError,
                           "\(error)")
        }
    }

    // MARK: - 什么时候再试

    func test_退避是_3_10_30_然后每分钟一次() {
        let delays = (0..<8).map { AuthStore.restoreRetryDelay(attempt: $0) }
        XCTAssertEqual(Array(delays.prefix(4)),
                       [.seconds(3), .seconds(10), .seconds(30), .seconds(60)])
        XCTAssertTrue(delays.dropFirst(3).allSatisfy { $0 == .seconds(60) },
                      "封顶 60 秒，不能无限拉长")
        XCTAssertEqual(delays, delays.sorted(), "不能越等越短")
    }

    func test_网络只有从断到通才立刻重试() {
        XCTAssertTrue(AuthStore.shouldRetryOnPathChange(from: false, to: true))

        XCTAssertFalse(AuthStore.shouldRetryOnPathChange(from: true, to: true))
        XCTAssertFalse(AuthStore.shouldRetryOnPathChange(from: true, to: false))
        XCTAssertFalse(AuthStore.shouldRetryOnPathChange(from: nil, to: false))
    }

    /// 最要紧的一条。开始监听时的第一次回调（`previous == nil`）如果说"通"，
    /// **不能**当成恢复信号：这次失败要是后端 5xx，网络本来就是通的——立刻重试、
    /// 失败、重开监听、又立刻收到"通"……就成了一个敲后端的死循环。
    func test_刚开始监听时本来就通_不算恢复信号() {
        XCTAssertFalse(AuthStore.shouldRetryOnPathChange(from: nil, to: true))
    }
}
