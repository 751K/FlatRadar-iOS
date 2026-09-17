import Foundation
import FlatRadarCore

/// 把 app 手上的数据整份写给主屏 / 锁屏小组件。
///
/// Mac 那边这件事在 ``AppFeed`` 里，因为那些数据本来就是跨窗口共享的一层。
/// iOS 没有那一层——store 都挂在 `FlatRadarApp` 上——所以单拎一个无状态的
/// 小工具出来，调用点全在 `FlatRadarApp` 的场景修饰符里。
///
/// **数据全部取自 app 已经有的东西**，只多拉一样：14 天的 `daily_new`
/// （柱子和 `+63%` 的基准都要它）。那是一条公开接口、十几个整数，而
/// `DashboardView` 自己拉的是 7 天那一份，够不上小组件要的 14 天。
@MainActor
enum WidgetPublisher {

    /// 14 天每日新增。拉一次存着，后面每次 publish 复用。
    private static var dailyNew: [Int] = []

    /// 柱子要 14 根（设计稿画的就是 14），基准也按 14 天算
    /// （`vs. 14-day average of 19`）。
    static let seriesDays = 14

    /// 拉那条序列。失败就留空——柱子和涨跌那一段整个不画，不编一条假曲线。
    static func refreshSeries() async {
        guard let chart = try? await APIClient.shared.getPublicChart(
            key: "daily_new", days: seriesDays) else { return }
        dailyNew = chart.data.map(\.count)
    }

    /// 把当前状态写进共享容器。
    ///
    /// 便宜：没有网络，就是攒一个结构体 + 一次原子写文件，而且
    /// ``WidgetBridge/publish(_:)`` 只在数字真变了的时候才踢时间轴。
    /// 所以调用点可以密一些，不必吝啬。
    static func publish(auth: AuthStore,
                        dashboard: DashboardStore,
                        listings: ListingsStore,
                        notifications: NotificationsStore) {
        let summary = dashboard.summary
        let me = dashboard.meSummary
        let unread = notifications.notifications.filter { !$0.isRead }

        WidgetBridge.publish(WidgetSnapshot(
            newToday: summary?.new24h,
            dailyNew: dailyNew,
            totalListings: summary?.total,
            statusChanges: summary?.changes24h,
            newThisWeek: summary?.new7d,
            // **匹配数走 `/me/summary`**，和这一端 Dashboard 上那张
            // 「Your matches」卡是同一个数。Mac 那边走的是 `/listings` 的
            // `total`——两端各自和自己屏幕上的数字对得上，这是有意的：
            // 小组件要先和它旁边那个 app 一致。
            matchCount: me?.matchedTotal,
            isFiltered: me?.filterActive ?? false,
            unreadAlerts: notifications.unreadCount,
            // 访客没有个人通知流，那个数永远是 0。
            showsUnread: !auth.isGuest,
            newest: Array(listings.listings.prefix(newestCount)).map(WidgetListing.init(listing:)),
            unreadKinds: auth.isGuest ? .none : UnreadBreakdown(
                newListings: unread.filter { $0.kind == .book }.count,
                statusChanges: unread.filter { $0.kind == .status }.count,
                lottery: unread.filter { $0.kind == .lottery }.count),
            // iOS 这边没有日历那一格（设计稿的 iOS 部分只有两格），所以不带
            // `moveIns`——它要一条 211 KB 的 `/calendar`，为一个不存在的格子
            // 去拉那个不值得。
            lastScrape: summary?.lastScrape ?? "",
            capturedAt: Date()))
    }

    /// NEWEST 那一段放几条。设计稿画的是三条。
    static let newestCount = 3

    /// 登出：那一格上的匹配数和未读是账户数据，得跟着窗口里的数据一起清。
    static func clear() { WidgetBridge.clear() }
}

private extension WidgetListing {
    /// 只搬画得出来的五个字段，不搬整个 `Listing`——那玩意带 features /
    /// featureMap / 坐标，几百字节一条，而共享容器那份 JSON 每次刷新都整份重写。
    init(listing: Listing) {
        self.init(id: listing.id,
                  name: listing.name,
                  city: listing.city,
                  platform: Platform.displayName(listing.source),
                  price: listing.priceRaw ?? "",
                  firstSeen: listing.firstSeen ?? "")
    }
}
