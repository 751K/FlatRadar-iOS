import SwiftUI
import WidgetKit
import FlatRadarCore

#if os(iOS)

/// 锁屏那三种挂件，设计稿 4c（圆形 / 矩形 / 内联）。
///
/// **这里一个自定义颜色都没有。** 锁屏挂件由系统统一染色（vibrant / 单色），
/// 我们那套暖纸底和红强调在上面根本不生效——硬塞只会得到一块灰。所以这一段
/// 不读 ``WidgetPalette``，底走 `AccessoryWidgetBackground()`，字走默认前景色。
/// 主屏那三档和它是两套画法，共用的是**数据和文案**，不是样式。
///
/// 内容仍然是同一个层级：圆形只放锚点（今日新增），矩形加未读和最新那一条，
/// 内联是一句话。
enum AccessoryFaces {

    /// 圆形：`31` 压着一行 `NEW`。
    struct Circular: View {
        let entry: SnapshotEntry

        var body: some View {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 1) {
                    Text(entry.snapshot?.newTodayText ?? StatusWording.countText(nil))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(StatusWording.newShort)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .textCase(.uppercase)
                }
            }
            .widgetLabel(StatusWording.newToday)
        }
    }

    /// 矩形：第一行 `31 new · 7 unread`，第二行最新那条房源。
    struct Rectangular: View {
        let entry: SnapshotEntry

        private var snapshot: WidgetSnapshot? { entry.snapshot }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(snapshot?.newTodayText ?? StatusWording.countText(nil))
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                    Text(headline)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                }
                Text(second)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }

        /// `new · 7 unread`。访客没有个人通知流，那半句整个不出现。
        private var headline: String {
            guard let snapshot, snapshot.showsUnread, snapshot.unreadAlerts > 0 else {
                return StatusWording.newLower
            }
            return "\(StatusWording.newLower) · \(snapshot.unreadAlerts) \(StatusWording.unreadLower)"
        }

        /// 第二行：最新那条的名字和价钱。
        ///
        /// 没有房源时退回时间那一句（新鲜说 `Scanned 4m ago`，过期说
        /// `Checked 3h ago`）——锁屏上一行空着比一行别的更糟，而"这是什么时候的
        /// 数"在任何一格都说得通。
        private var second: String {
            if let first = snapshot?.newest.first {
                let price = first.price.isEmpty ? "" : " · \(first.price)"
                return first.name + price
            }
            guard let snapshot else { return StatusWording.openApp }
            return StatusWording.sentence(snapshot.footnote(at: entry.date))
        }
    }

    /// 内联：锁屏时间下面那一行，`FlatRadar · 31 new today`。
    ///
    /// 系统只给一行文字加一个可选的小图，样式完全由它定——连字号都不是我们的。
    struct Inline: View {
        let entry: SnapshotEntry

        var body: some View {
            Text(StatusWording.inlineSummary(entry.snapshot?.newToday))
        }
    }
}

#endif
