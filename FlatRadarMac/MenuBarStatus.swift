import SwiftUI
import AppKit
import FlatRadarCore

/// 菜单栏常驻的存储键和文案口径。
///
/// 单独一个命名空间是因为这条设置有**三个**读者：`FlatRadarMacApp`（决定
/// `MenuBarExtra` 场景在不在）、`GeneralSettings`（那个开关）、``AppFeed``
/// （决定没窗口时 SSE 断不断）。三处各写一遍字符串迟早打错一个。
nonisolated enum MenuBarResidency {
    static let storageKey = "menuBarResident"

    /// 默认**不开**。
    ///
    /// 菜单栏图标是用户的地盘，不是应用可以默认占的。而且开着它就等于
    /// 「没有窗口也维持 SSE」（风险 6），那是一个明确的后台资源承诺，
    /// 该由用户自己按下，不该是安装后就有。
    static let defaultOn = false
}

/// 菜单栏那一格的内容。
///
/// Phase 4 的最后一条：「右上角显示当前匹配数 + 上次扫描时间」。
///
/// 这一屏和 iOS 那个「状态型小组件」是同一个东西，doc 里明写了**文案和口径要
/// 一致**。所以这里的数字全部走已有的口径函数：匹配数走 ``AppFeed/matchCount``
/// （服务端算的 `total`，和统计带上那个 `Matching filters` 是同一个数），
/// 时间走 ``SummaryModel/scannedAgoText``（`ServerTime.relativeTime`，
/// 记忆里那条「日期一律用 ServerTime」）。
///
/// 为什么用 `.window` 风格而不是普通菜单
/// ---------------------------------
/// 普通菜单只能排文字行。这一格的主体是一个**大数字**加两行说明，菜单画不出来；
/// 而且下面还要有 Refresh / Open 两个按钮和未读数，做成菜单项就是一串长得一样的
/// 灰行，扫不出重点。
struct MenuBarStatusView: View {

    let feed: AppFeed
    let auth: AuthStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline
            Divider().padding(.vertical, 12)
            rows
            Divider().padding(.vertical, 12)
            buttons
        }
        .padding(14)
        .frame(width: 260)
        // 打开面板就刷一次：菜单栏的数字过时了比没有更糟——它会被当成"刚扫完"。
        .task { await refresh() }
    }

    // MARK: - 上半

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(countLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(StatusWording.countText(feed.matchCount))
                    // 44pt 展示数字，和统计带、日历、Alerts 那三处同一档
                    // （见 ``Theme`` 顶部的字阶注释，写死磅值的三个例外之一）。
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .tracking(-1.4)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            Text(scannedLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // 这三句话（标题、大数字、时间）和桌面小组件用的是**同一份**，见
    // ``StatusWording``。原先这里各写一遍字面量，而上面那句注释说「没套就是
    // `Showing`」、它正下方的代码返回的却是 `Listings`——注释和代码在同一个
    // 屏幕上就已经漂了，正是把文案收成一份要防的那种事。
    private var countLabel: String {
        StatusWording.countLabel(isFiltered: feed.matchIsFiltered)
    }

    private var scannedLabel: String {
        guard let ago = feed.summary.scannedAgoText else {
            return StatusWording.scanTimeUnavailable
        }
        return StatusWording.scanned(ago)
    }

    // MARK: - 中间

    @ViewBuilder
    private var rows: some View {
        HStack {
            Text("Unread alerts")
                .font(.body)
            Spacer(minLength: 8)
            Text("\(feed.alerts.unreadCount)")
                .font(.body.monospacedDigit())
                .foregroundStyle(feed.alerts.unreadCount > 0 ? AnyShapeStyle(Color.primary)
                                                             : AnyShapeStyle(.secondary))
        }
        // 访客看不到这一行的意义：个人通知流对访客是关的（风险 6），
        // 数字永远是 0，摆在那里只会让人以为坏了。
        .opacity(auth.isGuest ? 0 : 1)
        .frame(height: 20)
    }

    // MARK: - 下半

    private var buttons: some View {
        VStack(spacing: 6) {
            ListingActionButton(title: "Open FlatRadar", prominent: true, fullWidth: true) {
                // 判据：「关闭所有窗口后菜单栏仍可查看状态并**重开窗口**」。
                //
                // `openWindow(id:)` 打开的是主 `WindowGroup`。如果已经有一个
                // 主窗口开着，这里走的是"把它激活"，不会再堆一个——`WindowGroup`
                // 对无参场景的语义就是这样。
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: FlatRadarMacApp.mainWindowID)
                dismiss()
            }

            HStack(spacing: 6) {
                ListingActionButton(title: refreshing ? "Refreshing…" : "Refresh",
                                    fullWidth: true) {
                    Task { await refresh() }
                }
                .disabled(refreshing)
                // ⌘Q 走系统那条路（`terminate`）：应用退出时 SSE 的 URLSession
                // 跟着进程一起没，判据里「⌘Q 完全退出并停止连接」因此是自动的。
                // 这里给一个可见入口，因为菜单栏面板不是菜单，没有系统的 Quit 项。
                ListingActionButton(title: "Quit", fullWidth: true) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await feed.refreshShared(auth: auth)
        refreshing = false
    }
}

/// 菜单栏上那个图标本身。
///
/// 带数字而不是光一个图标：这一格存在的理由就是"不打开窗口也知道有多少套"，
/// 图标不带数就得点开才知道，那和没有它区别不大。
struct MenuBarStatusLabel: View {

    let feed: AppFeed

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "house")
            if let n = feed.matchCount {
                Text("\(n)").monospacedDigit()
            }
        }
    }
}
