import SwiftUI
import FlatRadarCore

/// 通知屏：统计带 + 类型筛选条 + 按天分组的通知流 + 状态栏。
///
/// 设计稿里**没做**的那一块：Rules（多条规则）
/// ---------------------------------------
/// 设计稿的侧栏有一个 `Rules` 分区：四条带开关的规则（`Eindhoven ≤ €900` /
/// `Rotterdam, A+ or better` / `Studios, A+ or better` / `Pinned listings`，
/// 外加一条 `Lottery watch · paused until Monday`），统计带上有 `Active rules 4`，
/// 右栏还有 `Why you got this → Rule · Rotterdam, A+ or better` 和 `Mute rule`。
///
/// **后端只有一个筛选器。** `/me/filter` 是 GET / PUT 的**单数**端点，一个用户
/// 一份 ``ListingFilter``；没有"规则"这个概念，更没有每条规则的开关、暂停、
/// 命中计数。做成四条假规则、开关点了什么也不发生，比不做糟。
///
/// 不过设计稿最有价值的那一半**是能做的**：`Why you got this`。用户确实有一份
/// 筛选条件，只是**一份**而不是四条——右栏照样能把「你为什么收到这条」摊开成
/// 城市 / 能效 / 价格上限那几个 chip，见 ``InspectorPane``。
///
/// 设计稿里没做的只剩一处：`quiet hours 23:00 – 07:00`——整个后端搜不到任何
/// 免打扰时段的字段。
///
/// ⚠️ 这里原先还写着"`macOS notification + sound`：Mac 端还没接系统通知中心"。
/// **那是假的**，而且写下来之后一直没人回来改：``MacPushDelegate`` 实现了
/// `UNUserNotificationCenterDelegate`，`registerForRemoteNotifications()` 走
/// `NSApplication`，entitlements 里有 `com.apple.developer.aps-environment`，
/// 前台给的是 `[.banner, .sound, .list]`，点通知还会切到这一屏。
/// 设置页 Notifications tab 那个「Deliver notifications to this Mac」开关管的
/// 就是它。下面那条状态栏文案当时也照着这句假话写，一并改掉了。
///
/// 其余照做：统计带的大数 + 24 小时 2 小时分桶柱状图 + Today / Last 7 days、
/// 类型筛选 chip 带计数、`Unread only`、`Mark all read`、按天分组的流、
/// 每行的平台徽章和状态迁移胶囊、右栏详情。
struct AlertsPane: View {

    @Bindable var model: BrowseModel
    let store: NotificationsStore

    /// 底栏那句"会不会推到系统通知"。见下面 `deliveryStatusText`。
    @Environment(PushStore.self) private var push

    /// 类型筛选。`nil` = 全部。
    @State private var kindFilter: NotificationItem.Kind?
    @State private var unreadOnly = false

    var body: some View {
        VStack(spacing: 0) {
            statsStrip
                .padding(.horizontal, 18)
                .padding(.top, 12)
            filterBar
            Divider()
            feed
            Divider()
            statusBar
        }
    }

    // MARK: - 派生

    /// 解析结果和当前筛选下的分组，按输入缓存，见 ``AlertsDerived``。
    @State private var derived = AlertsDerived()

    private var parsed: AlertsDerived.Parsed { derived.parsed(store.notifications) }

    private var presented: AlertsDerived.Presented {
        derived.presented(store.notifications, kind: kindFilter, unreadOnly: unreadOnly, now: Date())
    }

    private var allRows: [AlertRow] { parsed.rows }
    private var rows: [AlertRow] { presented.rows }
    private var days: [AlertDay] { presented.days }
    private var totals: (today: Int, week: Int) { presented.totals }

    private func count(_ kind: NotificationItem.Kind?) -> Int {
        guard let kind else { return allRows.count }
        return parsed.counts[kind] ?? 0
    }

    // MARK: - 统计带

    private var statsStrip: some View {
        HStack(alignment: .center, spacing: 26) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Unread alerts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("\(store.unreadCount)")
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .tracking(-1.4)
                    .monospacedDigit()
                    .padding(.top, 2)
                Text(store.isLoading ? "loading…" : "of \(store.total) in total")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }

            VStack(alignment: .leading, spacing: 5) {
                BucketChart(values: presented.buckets)
                    .frame(width: 200, height: 46)
                Text("Last 24 hours, 2-hour buckets")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            HStack(alignment: .top, spacing: 30) {
                metric("Today", totals.today, "alerts")
                metric("Last 7 days", totals.week, "alerts")
            }
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .frame(height: 120)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(_ title: LocalizedStringKey, _ value: Int, _ caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text("\(value)")
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .padding(.top, 2)
            Text(caption).font(.caption).foregroundStyle(.tertiary).padding(.top, 1)
        }
    }

    // MARK: - 筛选条

    private var filterBar: some View {
        HStack(spacing: 8) {
            chip("All", kind: nil)
            chip("New", kind: .book)
            chip("Status", kind: .status)
            chip("Lottery", kind: .lottery)
            chip("System", kind: .system)
            Spacer(minLength: 12)
            Toggle("Unread only", isOn: $unreadOnly)
                .toggleStyle(.switch)
                .controlSize(.small)
            Button("Mark all read") { Task { await store.markAllRead() } }
                .controlSize(.small)
                .disabled(store.unreadCount == 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func chip(_ label: LocalizedStringKey, kind: NotificationItem.Kind?) -> some View {
        let selected = kindFilter == kind
        let n = count(kind)
        return Button { kindFilter = kind } label: {
            HStack(spacing: 5) {
                Text(label).font(.body.weight(selected ? .semibold : .regular))
                Text("\(n)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Theme.selectionFill : Color.primary.opacity(0.045)))
        }
        .buttonStyle(.plain)
        // 一条都没有的类型不给点——点了是一片空白，不如直接说明它没有。
        .disabled(n == 0 && kind != nil)
        .opacity(n == 0 && kind != nil ? 0.45 : 1)
    }

    // MARK: - 通知流

    @ViewBuilder
    private var feed: some View {
        if store.isLoading && store.notifications.isEmpty {
            centered { ProgressView() }
        } else if let error = store.errorMessage, store.notifications.isEmpty {
            centered {
                ContentUnavailableView("Could not load alerts", systemImage: "bell.slash",
                                       description: Text(error))
            }
        } else if days.isEmpty {
            centered {
                ContentUnavailableView(
                    unreadOnly ? "Nothing unread" : "No alerts yet",
                    systemImage: "bell",
                    description: Text(unreadOnly
                        ? "Everything here has been read."
                        : "Alerts arrive when a listing you match changes status."))
            }
        } else {
            // **不用** `List(selection:)`。
            //
            // 两个理由，和 ``ListingTable`` 是同一套：
            // - 系统的选中高亮在列表拿到键盘焦点时是**系统蓝**，`.tint()` 盖不住，
            //   会和 ``RowSurface`` 的液态玻璃打架；
            // - 行要自己画圆角、投影和玻璃，`List` 那套默认 chrome 得全关掉。
            //
            // 代价是方向键得自己接（下面的 `.onKeyPress`）——`List(selection:)`
            // 本来白送这个，换掉就必须补回来，否则是**功能倒退**。
            List {
                ForEach(days) { day in
                    Section {
                        ForEach(day.rows) { row in
                            // 悬停状态在行自己手里（见 ``AlertRowView``），跨行不重算整页。
                            AlertRowView(row: row, selected: model.focusedAlert == row.id)
                                .id(row.id)
                                .onTapGesture { select(row.id) }
                                .listRowInsets(EdgeInsets(top: 0, leading: 8,
                                                          bottom: 0, trailing: 8))
                                .listRowSeparator(.hidden)
                                // 行自己画背景，List 的默认底色全关掉。
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(day.label).font(.subheadline.weight(.semibold))
                            if day.unread > 0 {
                                Text("\(day.unread) unread")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                // 还有更多就给一个显式的按钮，不做滚动到底自动加载：
                // 这一屏会被 SSE 实时插入新行，滚动位置本来就不稳，
                // 再加一个"滚到底触发"很容易在插入时误触。
                if store.notifications.count < store.total {
                    Button("Load \(store.total - store.notifications.count) earlier alerts") {
                        Task { await store.loadMore() }
                    }
                    .buttonStyle(.link)
                    .disabled(store.isLoadingMore)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .focusable()
            // 关掉系统焦点环：`.focusable()` 会给整块列表套一圈蓝框，
            // 而选中状态已经由 ``RowSurface`` 表达了。同 ``ListingsPane``。
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.downArrow) { move(1); return .handled }
        }
    }

    /// ↑↓ 在**当前筛选后的**扁平顺序里走，不是在全集里——
    /// 开着 `Unread only` 时按方向键跳到一条看不见的行，是最难查的那种错。
    private func move(_ delta: Int) {
        let flat = days.flatMap(\.rows)
        guard !flat.isEmpty else { return }
        guard let current = model.focusedAlert,
              let index = flat.firstIndex(where: { $0.id == current })
        else {
            select(flat[0].id)
            return
        }
        let next = min(max(0, index + delta), flat.count - 1)
        select(flat[next].id)
    }

    /// 选中一条 = 右栏显示它，并把它标成已读。
    private func select(_ id: Int?) {
        // 详情焦点跟着一起换，换不过去就清空——见 ``BrowseModel/focusAlert(_:)``。
        model.focusAlert(id.flatMap { i in rows.first { $0.id == i } })
        guard let id,
              let item = store.notifications.first(where: { $0.id == id }),
              !item.isRead
        else { return }
        // 点开就算读过——和 Mail / 通知中心的惯例一致。
        Task { await store.markRead(ids: [id]) }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.revision > 0 ? Color.statusBook : Color.secondary)
                .frame(width: 6, height: 6)
            Text(store.revision > 0 ? "Live" : "Not connected")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text("\(store.notifications.count) of \(store.total) loaded")
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            // 设计稿这里写的是「Notifications on · quiet hours 23:00 – 07:00」。
            // 免打扰时段后端没有，那半句不能说；系统通知**是有的**，所以照实说。
            //
            // 原来这一行写的是「In-app only — no system notifications on Mac yet」——
            // 一句**给用户看的假话**，比旁边那句假注释更糟：它会让人以为要盯着
            // 这一屏才收得到。
            //
            // 状态跟着 `PushStore` 走，不写死：用户可能在设置里关掉了投递，
            // 也可能压根没给权限，那时候说"会通知你"同样是假的。
            Text(deliveryStatusText)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }
    /// 底栏右边那句话。三种状态，照实说：
    ///
    /// - 权限被拒 → 系统不会再弹，只能在这一屏看
    /// - 用户自己在设置里关了投递 → 同上，但原因不同，说法也要不同
    /// - 正常 → 说会推到通知中心
    ///
    /// 不写死任何一种：这一行的全部价值就是"我用不用盯着这一屏"，说错了
    /// 比不说更糟。
    private var deliveryStatusText: String {
        if push.permissionStatus == .denied {
            return String(localized: "In-app only — notifications are blocked in System Settings")
        }
        if push.deliveryDisabledByUser {
            return String(localized: "In-app only — delivery to this Mac is turned off")
        }
        return String(localized: "Also delivered to Notification Center")
    }

}

// MARK: - 一行

private struct AlertRowView: View {

    let row: AlertRow
    let selected: Bool

    /// 悬停是**这一行的**状态。原先放在 `AlertsPane` 上：鼠标每跨一行，整页 body
    /// 重算一次，而那一页读的是全部通知的解析结果。放进行里，跨行只重画两行。
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            // 未读圆点。已读时占位不画——不占位的话整列文字会左右跳。
            Circle()
                .fill(row.isRead ? Color.clear : Theme.ink)
                .frame(width: 6, height: 6)

            Text(row.time)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.body.weight(row.isRead ? .regular : .semibold))
                    .lineLimit(1)
                    .truncationMode(.head)      // 同楼单元名前缀一样，从头截
                Text(row.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let source = row.source { PlatformBadge(source: source) }
            transition
            Text(row.price ?? "—")
                .font(.body.weight(.medium))
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        // 选中 / 悬停的观感和列表屏**同一份配方**，见 ``RowSurface``：
        // 选中走液态玻璃，悬停整行浮起。
        .modifier(RowSurface(isSelected: selected, isHovered: hovered))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    /// `Reserved → ● Book`。旧状态用灰的中性胶囊，新状态用它自己的状态色——
    /// 眼睛要落在**变成了什么**上，而不是变之前是什么。
    @ViewBuilder
    private var transition: some View {
        HStack(spacing: 4) {
            if let from = row.from, from != row.to {
                Text(Theme.shortStatusLabel(ListingStatus.from(from)) ?? from)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            if let to = row.to {
                StatusPill(status: to, compact: true)
            }
        }
        .frame(width: 132, alignment: .trailing)
    }
}

// MARK: - 24 小时柱状图

/// 若干根柱子，旧 → 新。没有坐标轴、没有网格——和 ``Sparkline`` 同一条规则
/// （t2「去线留白」），颜色也和它同一个 token（``Theme/chart``）。
///
/// 两个读者：Alerts 那张 24 小时图（12 根，46pt 高），和菜单栏面板那排每日新增
/// （14 根，32pt 高）。面板那处原先自己写了一份，画出来最后一根是**纯黑**
/// （它用的是 ``Theme/ink``）——在一排灰柱里像一个洞，深色下反过来是一块白。
/// 这张图该长什么样这件事，这个文件里已经有答案了，不该再有第二份。
struct BucketChart: View {

    let values: [Int]

    /// 柱子的满高。调用点自己决定，因为这两处的容器高度差了 14pt。
    var height: CGFloat = 46

    /// 柱头的圆角。`nil` = 胶囊（圆角等于半宽）。
    ///
    /// 为什么要给出去而不是一律胶囊
    /// --------------------------
    /// 胶囊的圆角跟着**宽度**走。Alerts 那张图 12 根柱子摊在一整行里，每根够宽，
    /// 胶囊读出来是"圆头的柱子"；菜单栏面板 14 根挤在 130pt 里，每根只有 6pt 宽，
    /// 同一个 `Capsule()` 画出来是**一排药丸**——柱状图的形状语义没了，看着像一行
    /// 小图标。渲染出来才发现的，小组件那一轮栽过一模一样的一次。
    var cornerRadius: CGFloat?

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                // 最后一根是"当前这两个小时"，用实心的图表色点出来；其余用同色的淡版。
                //
                // 淡的那档用同一个蓝而不是中性灰：一张图里两种色相，眼睛会去猜灰和蓝
                // 各自代表什么，而这里它们只差"是不是当前"这一件事。
                //
                // 0.55 是**照 iOS 的柱子来的**（`DashboardView` 里 by-price / by-area
                // 那几组都是 `.blue.opacity(0.55)`）。原来这里是 0.22——那个数是配
                // 中性灰定的，灰在 0.22 上还看得见，同样透明度的蓝压在白底上会淡到
                // 像没画（实测过，一根 2pt 的柱子基本融进块底）。
                //
                // 全零的桶也画 2pt 的底，否则安静的时段会变成一段空白，
                // 读起来像"没有数据"而不是"没有通知"。
                barShape
                    .fill(index == values.count - 1 ? Theme.chart : Theme.chart.opacity(0.55))
                    .frame(height: max(2, height * CGFloat(value) / CGFloat(peak)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private var barShape: AnyShape {
        guard let cornerRadius else { return AnyShape(Capsule()) }
        return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
