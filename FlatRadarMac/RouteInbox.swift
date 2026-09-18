import SwiftUI

/// 要把用户带去的地方。
enum AppRoute: Equatable {
    /// 点了推送通知：切到 Alerts 屏，新来的那条就在最上面。
    ///
    /// 只切屏、不定位到具体哪一条：payload 里给的是 `listing_id` 不是通知 id，
    /// 同一套房可能有好几条通知。
    case alerts
    /// `h2smonitor://map/<id>`：切到地图屏并定位过去。
    case locateOnMap(listingID: String)
}

/// 应用级的"待去往"信箱。推送回调和 deep link 往里投，主窗口来取。
///
/// 为什么不再用 `NotificationCenter` 广播
/// ------------------------------------
/// 原先点了推送，``MacPushDelegate`` 就 post 一次 `.flatRadarOpenAlerts`，接收者是
/// `MainWindow` 上的 `.onReceive`（代码审查 P2）。广播是**发完即忘**的，于是：
///
/// - 关掉所有窗口、只剩菜单栏常驻时点通知：没有任何接收者，这次点击什么都没发生；
/// - 冷启动点通知：系统先把 app 拉起来，回调到的时候 `MainWindow` 还没挂上
///   （会话还在恢复，屏上是占位），同样没人接。
///
/// 信箱把"说一声"变成"留一张条"：投进来的那一条一直留着，**直到有一个主窗口
/// 把它取走**。没有窗口就顺手开一个。这也正好兑现了风险 6 那句「URL 与通知路由
/// 在未登录时暂存，认证后再执行」——没登录时 `MainWindow` 不存在，条子就一直等着。
///
/// 为什么是 `static let shared`
/// ---------------------------
/// 投件的一方是 ``MacPushDelegate`` 里的系统回调，取件的一方是窗口里的视图，
/// 两边没有共同的父视图可以传递同一个实例；而它在语义上就是一个进程一份。
/// 测试里的规则用例各自 `RouteInbox()` 一个新的，不碰这一份。
@MainActor
@Observable
final class RouteInbox {

    static let shared = RouteInbox()

    /// 每投一次加一。窗口靠它发现"有新的"——同一个去处连投两次也要生效。
    private(set) var seq = 0
    /// 最近投进来的那一条。
    private(set) var route: AppRoute?
    /// 已经被某个窗口取走的最后一个序号。
    private(set) var deliveredSeq = 0

    /// 现在挂着几个浏览窗口（``RootView``，登录屏也算——路由会在那儿等到登录完成）。
    @ObservationIgnored private(set) var browserWindows = 0

    /// 开一个浏览窗口。由挂着的视图登记，见 ``registerWindowOpener(_:)``。
    ///
    /// 信箱自己开不了窗口：SwiftUI 的 `openWindow` 只能从视图的环境里拿到，
    /// 而投件的系统回调在视图树外面。
    @ObservationIgnored private var openBrowserWindow: (() -> Void)?

    init() {}

    // MARK: - 投件

    func post(_ route: AppRoute) {
        seq += 1
        self.route = route
        // 一个窗口都没有：开一个。它挂上之后会来取这张条。
        if browserWindows == 0 { openBrowserWindow?() }
    }

    // MARK: - 取件

    /// 一个主窗口来取件。
    ///
    /// - Parameters:
    ///   - appliedSeq: 这个窗口自己已经接过的最后一个序号。
    ///   - justAppeared: 窗口是**刚出现**来取，还是**一直开着**、看到有新投递才来取。
    /// - Returns: 要执行的去处（可能没有），以及这个窗口该记下的新序号。
    ///
    /// 两种来取的规矩不一样：
    /// - **一直开着的窗口**：每条新投递都执行。开着两个窗口时两个都切过去——
    ///   这是改之前广播就有的行为，不在这次改动里变。
    /// - **刚出现的窗口**：只接**还没有任何窗口接过的**那一条。不然 ⌘N 开出来的
    ///   新窗口会把十分钟前那次点击再执行一遍，平白跳到 Alerts 屏。
    func claim(after appliedSeq: Int, justAppeared: Bool) -> (route: AppRoute?, seq: Int) {
        guard let route, seq > appliedSeq else { return (nil, max(seq, appliedSeq)) }
        if justAppeared && seq <= deliveredSeq { return (nil, seq) }
        deliveredSeq = seq
        return (route, seq)
    }

    // MARK: - 窗口登记

    func browserWindowAppeared() { browserWindows += 1 }
    func browserWindowDisappeared() { browserWindows = max(0, browserWindows - 1) }

    /// 登记"怎么开一个浏览窗口"。后登记的覆盖先登记的。
    ///
    /// 每个浏览窗口出现时都登记一次，菜单栏那一格也登记——后者是"一个窗口都没开过、
    /// 只有菜单栏图标"那种启动形态下唯一挂着的视图。
    func registerWindowOpener(_ open: @escaping () -> Void) {
        openBrowserWindow = open
    }
}
