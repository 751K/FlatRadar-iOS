import Foundation

/// 判断「该不该请用户去 App Store 评分」时看的那几个数。
///
/// 单独抽成值类型，是为了让 ``ReviewPromptPolicy/shouldAsk(_:trigger:now:)``
/// 能是个纯函数——那条判断链是这个功能里唯一会出错的地方（问早了惹人烦、
/// 问晚了那 3 次配额就浪费了），而它一旦写在 store 里就只能靠上架后观察。
nonisolated struct ReviewPromptState: Equatable, Sendable {
    /// 用过这个 App 的**不同日子**数，不是会话数。一天点五次说明不了什么。
    var activeDays: Int
    /// 累计打开过多少条房源详情。
    var listingOpens: Int
    /// 开着通知——这个 App 的核心价值就是「有新房源就告诉你」，
    /// 开了通知才说明用户认这件事。
    var hasNotifications: Bool
    var lastPromptedAt: Date?
    var lastPromptedVersion: String?
    var currentVersion: String
}

/// 什么时候问。
///
/// 两条**系统层面**的硬约束先摆着，它们决定了这套策略的形状：
///
/// 1. `requestReview` 每 365 天最多真正弹 3 次，调再多也一样，而且**调用方
///    无法知道有没有弹出来**。所以策略的意义不是"多问几次"，而是别把那 3 次
///    浪费在坏时刻上。
/// 2. Apple 明令禁止把它挂在「点这里评分」按钮上。想要手动入口只能用
///    `?action=write-review` 直达链接——设置页里那一行就是。
///
/// 时机选在**用户刚拿到价值、而且手上没事**的那一刻：看完一条房源详情退出来。
/// 「打开 App 时」是最差的时机——那时他什么都还没得到。
nonisolated enum ReviewPromptPolicy {

    enum Trigger: Sendable {
        /// 看完一条房源详情、退回列表。
        case listingClosed
        /// 打赏成功。
        case tipCompleted
    }

    static let minActiveDays = 3
    static let minListingOpens = 5
    /// 两次询问至少隔这么久。系统配额是每年 3 次，120 天正好把它摊开。
    static let cooldownDays: Double = 120

    static func shouldAsk(_ s: ReviewPromptState,
                          trigger: Trigger,
                          now: Date) -> Bool {
        // 同一个版本只问一次。跨版本重置，是因为「这一版变好了」本身就是重新
        // 征求意见的理由。
        if let asked = s.lastPromptedVersion, asked == s.currentVersion {
            return false
        }
        if let last = s.lastPromptedAt,
           now.timeIntervalSince(last) < cooldownDays * 86_400 {
            return false
        }

        switch trigger {
        case .tipCompleted:
            // 已经掏钱了，比任何启发式都准，不再要求别的门槛。
            return true
        case .listingClosed:
            return s.activeDays >= minActiveDays
                && s.listingOpens >= minListingOpens
                && s.hasNotifications
        }
    }
}

/// 评分引导的计数与去重。
///
/// 只负责「记数 + 判断能不能问」，**不负责问**——真正的 `requestReview` 是
/// SwiftUI 环境里的 `RequestReviewAction`，只能在视图里调，所以调用点在视图，
/// 这里只回答 Bool。
@MainActor
@Observable
final class ReviewPromptStore {

    private enum Key {
        static let activeDays = "review_active_days"
        static let lastActiveDay = "review_last_active_day"
        static let listingOpens = "review_listing_opens"
        static let lastPromptedAt = "review_last_prompted_at"
        static let lastPromptedVersion = "review_last_prompted_version"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// App 进入前台时调一次。同一天调多少次都只算一天。
    ///
    /// 用「日期字符串」而不是「距上次超过 24h」：用户每天早上通勤时看一眼，
    /// 按 24h 算会因为今天比昨天早了十分钟就不计数。
    func noteActiveDay(hasNotifications: Bool, now: Date = Date()) {
        self.hasNotifications = hasNotifications
        let today = Self.dayKey(now)
        guard defaults.string(forKey: Key.lastActiveDay) != today else { return }
        defaults.set(today, forKey: Key.lastActiveDay)
        defaults.set(defaults.integer(forKey: Key.activeDays) + 1, forKey: Key.activeDays)
    }

    /// 打开一条房源详情。加载成功才算——加载失败的那次用户什么也没看到。
    func noteListingOpened() {
        defaults.set(defaults.integer(forKey: Key.listingOpens) + 1, forKey: Key.listingOpens)
    }

    /// 现在该不该问。
    func shouldAsk(_ trigger: ReviewPromptPolicy.Trigger, now: Date = Date()) -> Bool {
        // 截图自动化下**绝不**弹。
        //
        // 这是和 `PushStore.requestPermissionAndRegister` 同一类的坑：系统弹窗会
        // 盖在界面正中间，而带系统弹窗的截图不能上架。2026-09-04 那批产出就是被
        // 通知权限框毁掉的，每种语言两张图作废。评分框比那个更难防——它由系统
        // 决定弹不弹，调用方看不到结果，所以只能在源头拦住。
        guard !CommandLine.arguments.contains("UI_TEST_SCREENSHOT_MODE") else {
            return false
        }
        return ReviewPromptPolicy.shouldAsk(currentState, trigger: trigger, now: now)
    }

    /// 问过了就记下来。**不管系统实际有没有弹**——调用方本来就无从知道，
    /// 而把「已经用掉一次机会」记成没用过，只会让下次更早地再问一遍。
    func markAsked(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: Key.lastPromptedAt)
        defaults.set(AppVersion.short, forKey: Key.lastPromptedVersion)
    }

    /// 登出不清这些数。评分意愿是**人**的属性，不是账号的——同一台设备换个
    /// 账号继续用，不该把「刚问过」这件事忘掉，否则换号就能绕过冷却。
    private var hasNotifications = false

    var currentState: ReviewPromptState {
        let ts = defaults.double(forKey: Key.lastPromptedAt)
        return ReviewPromptState(
            activeDays: defaults.integer(forKey: Key.activeDays),
            listingOpens: defaults.integer(forKey: Key.listingOpens),
            hasNotifications: hasNotifications,
            lastPromptedAt: ts > 0 ? Date(timeIntervalSince1970: ts) : nil,
            lastPromptedVersion: defaults.string(forKey: Key.lastPromptedVersion),
            currentVersion: AppVersion.short)
    }

    /// 设置页里那一行「去 App Store 评分」的目标。
    ///
    /// 手动入口只能走这个链接，不能调 `requestReview`——Apple 明确禁止把
    /// 系统评分框挂在按钮上。`?action=write-review` 会直接打开撰写评论界面。
    static let writeReviewURL = URL(
        string: "https://apps.apple.com/app/id6769857080?action=write-review")!

    private static func dayKey(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
