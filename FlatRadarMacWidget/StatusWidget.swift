import SwiftUI
import WidgetKit
import FlatRadarCore

/// 桌面上那一格：**今天有什么新的**。
///
/// 层级照搬列表页顶上的统计带（``StatsStrip``），那是这套界面里回答同一个问题
/// 的地方，它的设计稿结论写得很直接：
///
/// > 四张等重卡片是"乱"的来源 —— 它们互相竞争，眼睛没有落点。改成一个锚点：
/// > 打开 app 第一眼要看的是"现在有什么新的"，所以 New today 放大到 44px……
/// > 总房数、状态变更、平台数降级成右侧的小字。
///
/// 所以三档尺寸是**同一个层级的三次截断**，不是三种设计：
///
/// | | 放什么 | 为什么到此为止 |
/// |---|---|---|
/// | 小 | 锚点 + 涨跌 + 未读 | 128pt 宽只够一个 44pt 的数，再加一行就没有锚点了 |
/// | 中 | 锚点 + 右边三行小数 | 正好是统计带的结构，横过来的 |
/// | 大 | 再加 14 天柱子 + 第四个小数 | 高度够了才画得下"最近是多还是少"这个形状 |
///
/// **总匹配数不是锚点**。它在小号那一格里一个字都没有——那个数一天可能一点不
/// 变（个人筛选命中的池子本来就稳），拿它当第一眼要看的东西是浪费那 44pt。
/// 它从中号开始出现在右边的小数里，和统计带的位置一致。
struct StatusWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.status, provider: SnapshotProvider()) { entry in
            StatusFace(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("What's new")
        .description("New listings today, unread alerts, and when FlatRadar last scanned.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// 从环境里取尺寸档，其余交给 ``StatusLayout``。
///
/// 拆成两层只为一件事：**能在小组件宿主之外把这几档画出来看**。
/// `EnvironmentValues.widgetFamily` 在 SDK 里是只读的（没有 setter），而
/// `previewContext(WidgetPreviewContext(family:))` 在 Xcode 预览之外不起作用——
/// 试过，脚本里无论传哪一档画出来的都是 medium 那一版，于是"小号排得下吗"
/// 这个问题根本问不出来。尺寸档能当参数传之后才问得出来，而第一次问就答了
/// 两条：标题会折成两行、底下那行会被截成 `scanned…`。
struct StatusFace: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View { StatusLayout(entry: entry, family: family) }
}

struct StatusLayout: View {

    let entry: SnapshotEntry
    let family: WidgetFamily

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    private var isFresh: Bool { snapshot?.isFresh(at: entry.date) ?? false }

    var body: some View {
        switch family {
        case .systemLarge:  large
        case .systemMedium: medium
        default:            small
        }
    }

    // MARK: - 小

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleRow
            anchorNumber
            Spacer(minLength: 0)
            Footnote(entry: entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 中

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                titleRow
                anchorNumber
                Spacer(minLength: 0)
                Footnote(entry: entry)
            }
            // 锚点那一列吃掉左边一半多一点：44pt 的数字加 `+63%` 要 96pt，
            // 剩下的给右边三行标签——它们是 callout，短一点不影响读。
            .frame(maxWidth: .infinity, alignment: .topLeading)

            metrics(includeStatusChanges: false)
                .frame(width: 148)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 大

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            anchorNumber
            if let base = snapshot.flatMap({ DailyNew.baselineAverage($0.dailyNew) }) {
                Text(StatusWording.vsBaseline(base))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }

            if let series = snapshot?.dailyNew, series.count >= 3 {
                BarRow(values: series, highlight: series.count - 1)
                    .frame(height: 56)
                    .padding(.top, 14)
                    .accessibilityLabel("New listings over the last \(series.count) days")
            }

            Spacer(minLength: 12)

            metrics(includeStatusChanges: true)

            Spacer(minLength: 8)
            Footnote(entry: entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 零件

    /// 标题一行。**只有小号**在右边挂那个未读胶囊。
    ///
    /// 小号总共排得下三行，未读又必须出现——「有没有我没看的」和「今天有没有
    /// 新的」是一眼要同时回答的两件事——所以它只能挂在标题那一行的右端。
    ///
    /// 中号和大号**不挂**：那两档右边已经有一整行 `Unread 3`，同一个数念两遍；
    /// 而且锚点那一列只占一半宽，胶囊会停在整格的正中间，看起来像是右边那列
    /// 第一行的东西。第一次渲染出来就是这个毛病。
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(StatusWording.newToday)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if family == .systemSmall {
                Spacer(minLength: 4)
                if let snapshot, snapshot.showsUnread, snapshot.unreadAlerts > 0 {
                    UnreadPill(count: snapshot.unreadAlerts)
                }
            }
        }
    }

    /// 大数字 + 涨跌。和统计带的锚点逐项一致。
    private var anchorNumber: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            DisplayNumber(text: snapshot?.newTodayText ?? StatusWording.countText(nil),
                          dimmed: !isFresh)
            if let pct = snapshot?.changeVsBaseline {
                ChangeBadge(percent: pct)
            }
        }
        .padding(.top, 2)
    }

    /// 右边（中号）/ 下面（大号）那几行小数。
    ///
    /// 顺序是「离我最近的在上」：我的匹配数 → 我的未读 → 全库 → 全库的变更。
    /// 统计带是横排的，顺序反过来（全库在左），因为那一屏的主体是列表本身；
    /// 这里是一格独立的卡，读的人问的是"我怎么样"。
    @ViewBuilder
    private func metrics(includeStatusChanges: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            // 匹配数**只在套了个人筛选时**才是一条独立的信息。
            //
            // 没套筛选的时候 `/listings` 的 total 就是全库的 total，这一行和下面
            // 那行 `Total listings` 是**同一个数**——渲染访客那一版时一眼看到：
            // `Listings 892` / `Total listings 892`，两行一模一样，还得让人
            // 想一想它们是不是两回事。
            if snapshot?.isFiltered ?? false {
                MetricRow(title: StatusWording.countLabel(isFiltered: true),
                          value: snapshot?.matchCount, dimmed: !isFresh)
            }
            if snapshot?.showsUnread ?? false {
                MetricRow(title: StatusWording.unread,
                          value: snapshot?.unreadAlerts, dimmed: !isFresh)
            }
            MetricRow(title: StatusWording.totalListings,
                      value: snapshot?.totalListings, dimmed: !isFresh)
            if includeStatusChanges {
                MetricRow(title: StatusWording.statusChanges,
                          value: snapshot?.statusChanges, dimmed: !isFresh)
            }
        }
    }
}

// MARK: - 预览

#Preview("Small", as: .systemSmall) {
    StatusWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .sample)
    SnapshotEntry(date: Date(), snapshot: nil)
}

#Preview("Medium", as: .systemMedium) {
    StatusWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .sample)
}

#Preview("Large", as: .systemLarge) {
    StatusWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .sample)
}
