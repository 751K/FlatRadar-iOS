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
/// 一并没做的还有两处，都是没有后端：
/// - `quiet hours 23:00 – 07:00`：整个后端搜不到任何免打扰时段的字段；
/// - `macOS notification + sound`：Mac 端还没接系统通知中心（包里的
///   `PushStore` 是 APNs/iOS 那条线）。说"已经用系统通知提醒你了"是假话。
///
/// 其余照做：统计带的大数 + 24 小时 2 小时分桶柱状图 + Today / Last 7 days、
/// 类型筛选 chip 带计数、`Unread only`、`Mark all read`、按天分组的流、
/// 每行的平台徽章和状态迁移胶囊、右栏详情。
struct AlertsPane: View {

    @Bindable var model: BrowseModel
    let store: NotificationsStore

    /// 类型筛选。`nil` = 全部。
    @State private var kindFilter: NotificationItem.Kind?
    @State private var unreadOnly = false
    @State private var hoveredID: Int?

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

    private var allRows: [AlertRow] {
        store.notifications.map { AlertFeed.row($0, platforms: Platform.knownKeys) }
    }

    private var rows: [AlertRow] {
        allRows.filter { row in
            (kindFilter == nil || row.kind == kindFilter) && (!unreadOnly || !row.isRead)
        }
    }

    private var days: [AlertDay] { AlertFeed.days(rows) }
    private var totals: (today: Int, week: Int) { AlertFeed.totals(allRows) }

    /// 筛选条上每个 chip 的计数。**永远按全集算**，不跟着当前筛选变——
    /// 否则点了 `Status` 之后其它 chip 全变成 0，就没法用它们跳转了。
    private func count(_ kind: NotificationItem.Kind?) -> Int {
        kind == nil ? allRows.count : allRows.filter { $0.kind == kind }.count
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
                BucketChart(values: AlertFeed.buckets(allRows))
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

    private func metric(_ title: String, _ value: Int, _ caption: String) -> some View {
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

    private func chip(_ label: String, kind: NotificationItem.Kind?) -> some View {
        let selected = kindFilter == kind
        let n = count(kind)
        return Button { kindFilter = kind } label: {
            HStack(spacing: 5) {
                Text(label).font(.callout.weight(selected ? .semibold : .regular))
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
                            AlertRowView(row: row,
                                         selected: model.focusedAlert == row.id,
                                         hovered: hoveredID == row.id)
                                .id(row.id)
                                .onHover { inside in
                                    if inside {
                                        hoveredID = row.id
                                    } else if hoveredID == row.id {
                                        hoveredID = nil
                                    }
                                }
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
        model.focusedAlert = id
        let row = id.flatMap { i in rows.first { $0.id == i } }
        model.focusedAlertRow = row
        // 详情焦点也跟过去：右栏上半是这条通知，下半是它说的那套房。
        // 不跟的话下半段还停在列表屏选中的那条，上下两截对不上。
        // 房源不在已加载的那批里就保持不动——总比清空好，至少不是空白。
        if let listingID = row?.listingID, model.listing(listingID) != nil {
            model.focused = listingID
        }
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
            // 后端没有免打扰时段，Mac 端也还没接系统通知中心——两句都不能说。
            Text("In-app only — no system notifications on Mac yet")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }
}

// MARK: - 一行

private struct AlertRowView: View {

    let row: AlertRow
    let selected: Bool
    let hovered: Bool

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
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        // 选中 / 悬停的观感和列表屏**同一份配方**，见 ``RowSurface``：
        // 选中走液态玻璃，悬停整行浮起。
        .modifier(RowSurface(isSelected: selected, isHovered: hovered))
        .contentShape(Rectangle())
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

/// 12 根柱子，旧 → 新。没有坐标轴、没有网格——和 ``Sparkline`` 同一条规则
/// （t2「去线留白」）。
struct BucketChart: View {

    let values: [Int]

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                // 最后一根是"当前这两个小时"，用墨色点出来；其余用淡的。
                // 全零的桶也画 2pt 的底，否则安静的时段会变成一段空白，
                // 读起来像"没有数据"而不是"没有通知"。
                Capsule()
                    .fill(index == values.count - 1 ? Theme.ink : Color.primary.opacity(0.22))
                    .frame(height: max(2, 46 * CGFloat(value) / CGFloat(peak)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
