import XCTest
@testable import FlatRadarCore

/// ``AuthStore/sessionIdentity``：宿主靠它判断"换了一个人没有"。
///
/// 原先宿主用的是 `isAuthenticated`，而游客和正式用户都是 true——游客在设置里
/// 注册之后，以它为 id 的任务不重跑（SSE 不连）、主窗口不重建（留着游客时期的
/// 数据）。代码审查 P2。
final class SessionIdentityTests: XCTestCase {

    private func identity(_ authed: Bool, _ role: Role, _ name: String? = nil) -> String? {
        AuthStore.sessionIdentity(isAuthenticated: authed, role: role, userName: name)
    }

    /// 就是那个 bug：游客注册成正式用户，这个值必须变。
    func test_游客注册成正式用户_身份变了() {
        XCTAssertNotEqual(identity(true, .guest), identity(true, .user, "kong"))
    }

    func test_没登录就没有身份_不管角色字段残留成什么() {
        XCTAssertNil(identity(false, .guest))
        XCTAssertNil(identity(false, .user, "kong"))
    }

    func test_不同的人不同_同一个人不变() {
        XCTAssertNotEqual(identity(true, .user, "a"), identity(true, .user, "b"))
        XCTAssertNotEqual(identity(true, .user, "a"), identity(true, .admin, "a"))
        // 同一个人要**稳定**：否则主窗口会在毫无变化时被重建，排序和选中全丢。
        XCTAssertEqual(identity(true, .user, "a"), identity(true, .user, "a"))
    }
}
