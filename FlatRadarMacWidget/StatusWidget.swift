import SwiftUI
import WidgetKit
import FlatRadarCore

/// 桌面上那一格：**当前匹配数 + 后端上次扫描是什么时候**。
///
/// docs/NEXT.md 对它的定义只有一行——「上次扫描时间 + 我的匹配数。**不做房源
/// 列表**」。不做列表是有道理的：桌面小组件不能滚动、不能翻页，一格塞三条房源
/// 只能塞三条，而这个 app 的人一天可能收十几条推送。它回答的是「还要不要打开
/// 我」，不是「今天有哪些房」。
///
/// 数字从哪儿来见 ``WidgetSnapshot``——一句话：**这一格不联网**，宿主 app 算完
/// 写进共享容器，这边只负责画。
struct StatusWidget: Widget {

    /// 改这个串等于换一个 widget：用户桌面上已经摆着的那一格会变成空白，
    /// 得手动删了重摆。所以它一旦发出去就不能再动。
    static let kind = "FlatRadarStatus"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: StatusProvider()) { entry in
            StatusFace(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Status")
        .description("Your current match count and when FlatRadar last scanned.")
        // 只给这两档。`systemLarge` 再大也没有第三样东西可放——多出来的空间
        // 只会变成留白，或者诱使人往里塞一个"不做"的房源列表。
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 时间轴

/// `nonisolated` 和下面的 provider 是一起的：`Entry` 是 `TimelineProvider` 的
/// 关联类型，它要是主 actor 隔离的，整个 conformance 就跟着被拖过去，
/// provider 那边单独标 `nonisolated` 也没用（错误信息是
/// 「conformance ... crosses into main actor-isolated code」，指的正是这里）。
nonisolated struct StatusEntry: TimelineEntry {
    let date: Date
    /// `nil` = 共享容器里什么都没有：这台 Mac 还没跑过 app，或者刚登出。
    let snapshot: WidgetSnapshot?
}

/// `nonisolated`：这个 target 和 app target 一样开着
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，而 `TimelineProvider` 的三个
/// 方法在 SDK 里是 nonisolated 的（WidgetKit 在自己的队列上调它们）。不写这一行
/// 就是「主 actor 隔离的方法不满足 nonisolated 的协议要求」三连报错。
///
/// 记忆里那条「默认 MainActor 隔离 vs 系统回调」说的就是这类：凡是系统回过来
/// 调你的东西，都得自己把隔离摘掉。
nonisolated struct StatusProvider: TimelineProvider {

    /// 图库里那张占位图。WidgetKit 管这叫 snapshot，和 ``WidgetSnapshot`` 不是
    /// 一回事——前者是"一张静态预览图"，后者是我们的数据。
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: Self.sample)
    }

    /// 小组件图库里那一格的预览。`context.isPreview` 时给示例数据而不是真数据：
    /// 用户还没把它摆上桌面，这时候给一个 `—` 的空格子，看起来就像坏的。
    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        let real = WidgetBridge.read()
        completion(StatusEntry(date: Date(),
                               snapshot: context.isPreview ? (real ?? Self.sample) : real))
    }

    /// 一次给足接下来 24 小时的条目。
    ///
    /// 为什么要给这么多：这一格的文字**自己会变旧**（`4m ago` → `5m ago`），
    /// 而 WidgetKit 不会主动重画——每一次该变的时刻都得在时间轴里列出来。
    /// 具体给哪些时刻是 ``WidgetSnapshot/refreshPoints(from:)`` 的事，它按
    /// ``ServerTime`` 的分档走。
    ///
    /// 数据本身在这 24 小时里**不会变**：这一格不联网，新数据只能由 app 写进来，
    /// 而 app 写完会自己踢一次时间轴（``WidgetBridge/publish(_:)``）。所以每个
    /// 条目挂的是同一份快照，变的只是"现在几点"。
    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetBridge.read()
        let points = (snapshot ?? .placeholder(at: now)).refreshPoints(from: now)
        let entries = points.map { StatusEntry(date: $0, snapshot: snapshot) }
        // 24 小时后再问一次。真正的更新走 app 那条主动踢的路，这里只是兜底：
        // 万一 app 一直没跑，至少那行 `checked 2d ago` 还会往前走。
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(24 * 3600))))
    }

    /// 图库预览和占位用的示例。数字取自设计稿那张图。
    ///
    /// `lastScrape` 用 `ISO8601Format()` 现算而不是写一个固定串：写死的话预览里
    /// 那行字会是 `scanned 412d ago`，看起来像坏的。`ServerTime.parse` 认得它
    /// （不带小数秒的那一档）。
    static var sample: WidgetSnapshot {
        WidgetSnapshot(
            matchCount: 193, isFiltered: true,
            lastScrape: Date().addingTimeInterval(-4 * 60).ISO8601Format(),
            newToday: 12, unreadAlerts: 3, showsUnread: true, capturedAt: Date())
    }
}

// MARK: - 画

/// 从环境里取尺寸档，其余交给 ``StatusLayout``。
///
/// 拆成两层只为一件事：**能在小组件宿主之外把这两档画出来看**。
/// `EnvironmentValues.widgetFamily` 在 SDK 里是只读的（没有 setter），而
/// `previewContext(WidgetPreviewContext(family:))` 在 Xcode 预览之外不起作用——
/// 试过，脚本里无论传哪一档画出来的都是 medium 那一版，于是"小号排得下吗"
/// 这个问题根本问不出来。尺寸档能当参数传之后才问得出来，而第一次问就答了
/// 两条：标题会折成两行、底下那行会被截成 `scanned…`。
struct StatusFace: View {

    let entry: StatusEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        StatusLayout(entry: entry, family: family)
    }
}

struct StatusLayout: View {

    let entry: StatusEntry
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .systemMedium:
            HStack(alignment: .top, spacing: 12) {
                countBlock
                Spacer(minLength: 0)
                sideRows
            }
        default:
            countBlock
        }
    }

    // MARK: 主体

    /// 顺序和菜单栏那一格（``MenuBarStatusView``）完全一样：标题、大数字、时间。
    /// 那不是巧合——两处是同一件事的两个位置，站在哪儿看到的都该是同一张脸。
    private var countBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(count)
                // 44pt 展示数字：菜单栏、统计带、日历、Alerts 用的是同一档
                // （见 ``Theme`` 的字号一节，写死磅值的三个例外之一）。
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .tracking(-1.4)
                .monospacedDigit()
                .lineLimit(1)
                // 五位数（`10000` 以上）在小号那一格会顶到边。缩而不是截：
                // 一个被截掉最后一位的数字是**错的**，小一号的还是对的。
                .minimumScaleFactor(0.5)
                // 数据过期时压成次要色。那行小字已经说了它是几时取的，
                // 这里再给一个不用读字就能看出来的信号。
                .foregroundStyle(isFresh ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer(minLength: 0)
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 中号那一格右边的两行。小号放不下，所以它们只在这儿出现。
    @ViewBuilder
    private var sideRows: some View {
        if let snapshot = entry.snapshot {
            VStack(alignment: .trailing, spacing: 8) {
                if let today = snapshot.newToday {
                    // 和统计带上那一格同名（`New today`），同一个数。
                    sideRow("New today", today)
                }
                // 访客那一行永远是 0，不摆。菜单栏那一格是同样的判断。
                if snapshot.showsUnread {
                    sideRow("Unread", snapshot.unreadAlerts)
                }
            }
        }
    }

    private func sideRow(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("\(value)")
                .font(.title2)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 文案
    //
    // 三个值都由 ``WidgetSnapshot`` 给，这里一个字都不自己拼——那正是
    // 「文案和口径要一致」落地的地方。

    private var label: String { entry.snapshot?.countLabel ?? "Listings" }

    private var count: String { entry.snapshot?.countText ?? "—" }

    private var isFresh: Bool { entry.snapshot?.isFresh(at: entry.date) ?? false }

    /// 没有快照时说的是**该做什么**，不是"没有数据"。
    ///
    /// 这一格是空的只有两种原因（没登录 / 这台 Mac 还没跑过 app），
    /// 两种的下一步动作是同一个，所以不必分辨，直接说那个动作。
    private var footnote: String {
        entry.snapshot?.footnote(at: entry.date) ?? "Open FlatRadar"
    }
}

// MARK: - 预览

#Preview("Small", as: .systemSmall) {
    StatusWidget()
} timeline: {
    StatusEntry(date: Date(), snapshot: StatusProvider.sample)
    // 过期那一版：数字变浅，底下那行改口说"这份数据是几时取的"。
    StatusEntry(date: Date(), snapshot: WidgetSnapshot(
        matchCount: 193, isFiltered: true, lastScrape: "", newToday: 12,
        unreadAlerts: 3, showsUnread: true,
        capturedAt: Date().addingTimeInterval(-3 * 3600)))
    // 还没登录 / 还没跑过 app。
    StatusEntry(date: Date(), snapshot: nil)
}

#Preview("Medium", as: .systemMedium) {
    StatusWidget()
} timeline: {
    StatusEntry(date: Date(), snapshot: StatusProvider.sample)
}
