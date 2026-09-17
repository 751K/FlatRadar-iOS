import XCTest
@testable import FlatRadarCore

/// ``AuthStore/isRestoringSession`` 要守住的两条。
///
/// 这个标志是为了修一个**看得见但查不出**的现象：Mac 端自动登录进去之后，
/// 房源列表上浮着一个系统的密码自动填充建议框。成因是宿主那句
/// `if auth.isAuthenticated { 主界面 } else { 登录页 }`——`isAuthenticated`
/// 一开始是 false，而恢复会话要等一次网络往返，于是冷启动必定先渲染一次登录
/// 页；那上面 `.textContentType(.password)` 的输入框成了新窗口的第一响应者，
/// macOS 就把密码建议弹了出来，而它是独立的系统窗口，主界面换上来之后还浮着。
///
/// 真机量过：改之前登录表单在屏上待 677ms，改之后那条分支一次都不进。
///
/// 两条不变式：
/// 1. **判据要和 `restoreSession` 取 token 的地方一致。** 这边说"有会话要恢复"
///    而那边取不到，界面就会停在占位屏上等一个永远不来的结果。
/// 2. **不管从哪条路返回，标志都要落下。** `restoreSession` 有两处提前 return
///    （UI 测试开关、根本没有 token），漏掉任何一处都是卡在占位屏上。
@MainActor
final class SessionRestoreStateTests: XCTestCase {

    private static let tokenKey = "auth_token"
    private var savedToken: String?

    override func setUp() {
        super.setUp()
        savedToken = UserDefaults.standard.string(forKey: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
    }

    override func tearDown() {
        if let savedToken {
            UserDefaults.standard.set(savedToken, forKey: Self.tokenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        }
        super.tearDown()
    }

    /// 没有会话可恢复时**不进占位屏**：直接是登录页，那种情况下弹自动填充
    /// 正是应该的。
    ///
    /// 这条依赖"这台机器的钥匙串里没有这个 server 的 token"。开发机上登录着
    /// 的话它就不成立——那不是回归，所以跳过而不是失败。
    func test_没有存过会话就不用等() throws {
        try XCTSkipUnless(KeychainManager.load(server: "flatradar.app") == nil,
                          "这台机器的钥匙串里存着 token，这条测不了")
        XCTAssertFalse(AuthStore().isRestoringSession)
    }

    /// 存过会话时，第一帧之前就要知道"要等"。
    ///
    /// 从 false 开始再异步改成 true 是不够的——弹出自动填充只需要那一帧。
    func test_存过会话时第一帧就在等() {
        UserDefaults.standard.set("a-token", forKey: Self.tokenKey)
        XCTAssertTrue(AuthStore().isRestoringSession,
                      "构造完就该是「恢复中」。晚一帧，登录表单就已经上过场了。")
    }

    /// `restoreSession` 走到「根本没有 token」那条提前 return 时，标志同样要落下。
    ///
    /// 这条模拟的是「构造时有 token、真去取的时候没了」——比如另一个进程清了
    /// 钥匙串。不走网络：`guard let savedToken else { return }` 之前不发请求。
    func test_提前返回也要把等待状态落下() async {
        UserDefaults.standard.set("a-token", forKey: Self.tokenKey)
        let auth = AuthStore()
        XCTAssertTrue(auth.isRestoringSession)

        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        await auth.restoreSession()

        XCTAssertFalse(auth.isRestoringSession,
                       "提前 return 也要落下，否则界面永远停在占位屏上。")
        XCTAssertFalse(auth.isAuthenticated)
    }

    /// 判据本身：和 `restoreSession` 读的是同两个位置。
    func test_判据认_UserDefaults_那个回退位() {
        let server = "example.invalid"
        XCTAssertFalse(AuthStore.hasPersistedSession(server: server))
        UserDefaults.standard.set("a-token", forKey: Self.tokenKey)
        XCTAssertTrue(AuthStore.hasPersistedSession(server: server))
    }
}
