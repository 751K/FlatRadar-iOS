import Foundation

/// UNREAD 那一格下半部分的三行。
///
/// 设计稿 4a 第二张小卡：◆ New listings / ● Status changes / ● Lottery。
/// 三个数就是 ``NotificationItem/Kind`` 里的 `.book` / `.status` / `.lottery`，
/// 不是另一套分类——那个 `kind` 是后端 `type` 加正文启发式判出来的，
/// 判错过一次（`new_listing` 的正文里那个 `→` 是入住日，被当成状态迁移，
/// Mac 实测 17 条全判成 Status），所以这里**不再自己判一遍**，直接用它。
public nonisolated struct UnreadBreakdown: Codable, Sendable, Equatable {

    /// 新上架（`.book`）。设计稿里是红菱形那一行。
    public let newListings: Int
    /// 状态变化（`.status`）。蓝点。
    public let statusChanges: Int
    /// 抽签（`.lottery`）。棕点。
    public let lottery: Int

    public init(newListings: Int, statusChanges: Int, lottery: Int) {
        self.newListings = newListings
        self.statusChanges = statusChanges
        self.lottery = lottery
    }

    public static let none = UnreadBreakdown(newListings: 0, statusChanges: 0, lottery: 0)

    /// 三行加起来。
    ///
    /// **不拿它当头条那个大数字**：头条用服务端给的 `unread`，这三行是**已经
    /// 拉回本地那些未读**的分类。`NotificationsStore` 会一直翻页翻到
    /// `unreadCount <= loadedUnreadCount` 为止，所以正常情况下两者相等；
    /// 真要不等（翻页失败），头条那个才是对的，这三行只是没数全。
    public var total: Int { newListings + statusChanges + lottery }

    /// 三行都是 0 —— 那就整段不画，而不是画三行 0。
    public var isEmpty: Bool { total == 0 }
}
