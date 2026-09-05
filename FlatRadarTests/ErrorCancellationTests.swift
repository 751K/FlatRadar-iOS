import XCTest
@testable import FlatRadar

/// `Error.isCancellation`。
///
/// 守的是一句弹给用户的天书
/// ------------------------
/// 2026-09-05，日历和 Alerts 两个页面会弹出：
///
///     Refresh Failed
///     The operation couldn't be completed. (Swift.CancellationError error 1.)
///
/// 来源是 SwiftUI 的 `.task` / `.refreshable`：视图消失、被重建、或者切走 tab 时
/// 它会 cancel 里面的 Task，`URLSession` 抛 `URLError.cancelled`，`APIClient` 把它
/// 归一成 `CancellationError`，然后 store 的 catch 一视同仁地写进 `errorMessage`,
/// 视图再把它弹出来。
///
/// **取消不是失败**：弹的那一刻界面通常是好的，数据要么本来就在，要么下一次
/// `.task` 马上会重拉。所以这个判定必须把三种形态都认出来——漏掉任何一种，那句
/// 天书就会从那条路径重新冒出来。
final class ErrorCancellationTests: XCTestCase {

    /// `APIClient` 归一之后的形态，也是 `Task.checkCancellation()` 抛的那个。
    func testCancellationErrorIsCancellation() {
        XCTAssertTrue(CancellationError().isCancellation)
    }

    /// 没走 `APIClient` 的直接调用拿到的是 URLError。
    func testURLErrorCancelledIsCancellation() {
        XCTAssertTrue(URLError(.cancelled).isCancellation)
    }

    /// `APIError.network` 是原样包装的，取消可能藏在里面。
    func testNetworkWrappedCancellationIsCancellation() {
        XCTAssertTrue(APIError.network(CancellationError()).isCancellation)
        XCTAssertTrue(APIError.network(URLError(.cancelled)).isCancellation)
    }

    /// 真失败必须照报，否则这个修法会把网络错误一起吞掉。
    func testRealFailuresAreNotCancellation() {
        XCTAssertFalse(URLError(.notConnectedToInternet).isCancellation)
        XCTAssertFalse(URLError(.timedOut).isCancellation)
        XCTAssertFalse(APIError.network(URLError(.timedOut)).isCancellation)
        XCTAssertFalse(APIError.serverError("boom").isCancellation)
        XCTAssertFalse(APIError.unauthorized("nope").isCancellation)
        XCTAssertFalse(APIError.decoding(URLError(.cannotParseResponse)).isCancellation)
    }

    /// `.decoding` 里就算真包着取消也不算——解码阶段已经拿到数据了，
    /// 那儿的 `URLError` 只可能是被错误地传进来的。这条钉住「只认 network 分支」。
    func testDecodingBranchIsNotUnwrapped() {
        XCTAssertFalse(APIError.decoding(CancellationError()).isCancellation)
    }
}
