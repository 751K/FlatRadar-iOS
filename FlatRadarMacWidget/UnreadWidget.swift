import SwiftUI
import WidgetKit
import FlatRadarCore

/// 桌面上第二格：**有多少条我还没看**。
///
/// 设计稿 4a 左栏第二张小卡。单独一格而不是塞进状态那一格里，是设计稿那句总纲的
/// 直接结果——「**小号只回答一个问题**（今日新增多少 / 未读多少）」：那是**两个**
/// 问题，所以是两格，各自用整块 46pt 的数字回答自己那个。
///
/// 只给小号。中号 / 大号的未读已经在状态那一格里（标题行的红胶囊、大号的统计格），
/// 再做一份大的就是同一个数在同一块屏幕上出现两次。
struct UnreadWidget: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.unread, provider: SnapshotProvider()) { entry in
            WidgetSurface { UnreadFace(entry: entry) }
        }
        .configurationDisplayName("Unread")
        .description("How many alerts you haven't read, split by what they are.")
        .supportedFamilies([.systemSmall])
    }
}

struct UnreadFace: View {

    let entry: SnapshotEntry
    @Environment(\.palette) private var palette

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    private var isFresh: Bool { snapshot?.isFresh(at: entry.date) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Ring(color: palette.accent)
                SectionLabel(text: StatusWording.unread)
            }
            Spacer(minLength: 4)
            DisplayNumber(text: headline, size: 46, dimmed: !isFresh)
            Spacer(minLength: 4)
            breakdown
        }
    }

    /// 访客没有个人通知流（风险 6），这个数永远是 0——显示 `—` 而不是 `0`，
    /// 因为 0 是「都看过了」，而访客的情况是「这件事对你不存在」。
    private var headline: String {
        guard let snapshot, snapshot.showsUnread else { return StatusWording.countText(nil) }
        return StatusWording.countText(snapshot.unreadAlerts)
    }

    /// 三行分类。空的时候整段不画——三行 0 不比没有这三行多说任何事。
    @ViewBuilder
    private var breakdown: some View {
        if let kinds = snapshot?.unreadKinds, !kinds.isEmpty {
            VStack(spacing: 5) {
                if kinds.newListings > 0 {
                    KindRow(symbol: AnyView(Diamond(color: palette.accent, size: 5)),
                            title: StatusWording.kindNewListings, value: kinds.newListings)
                }
                if kinds.statusChanges > 0 {
                    KindRow(symbol: AnyView(Dot(color: palette.status)),
                            title: StatusWording.kindStatusShort, value: kinds.statusChanges)
                }
                if kinds.lottery > 0 {
                    KindRow(symbol: AnyView(Dot(color: palette.lottery)),
                            title: StatusWording.kindLottery, value: kinds.lottery)
                }
            }
        } else {
            LiveFooter(entry: entry)
        }
    }
}

#Preview("Unread", as: .systemSmall) {
    UnreadWidget()
} timeline: {
    SnapshotEntry(date: Date(), snapshot: .sample)
    SnapshotEntry(date: Date(), snapshot: nil)
}
