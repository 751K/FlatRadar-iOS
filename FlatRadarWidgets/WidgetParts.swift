import SwiftUI
import WidgetKit
import FlatRadarCore

// 设计稿里反复出现的几块。全部按「靠填充差分组，不描边」那条规则做。

/// 一排柱子：14 天每日新增。
///
/// 没有坐标轴、没有网格、没有图例——和统计带那条曲线、Alerts 那 12 根柱子同一条
/// 规则（设计稿 t2「去线留白」）。最后一根是今天，染成强调红。
///
/// 柱子**平分整条宽度**（设计稿是 `flex:1`）：14 根摊在 140pt 里约 7pt 一根，
/// 配 2pt 圆角就是柱子。之前一版给柱宽封了 10pt 的顶，那是为了修「18pt 宽的
/// `Capsule` 变成药丸」——换成固定小圆角之后不需要封顶了，平分反而更贴稿。
struct BarRow: View {
    let values: [Int]
    var spacing: CGFloat = 3
    var radius: CGFloat = 1.5
    var dimmed = false
    @Environment(\.palette) private var palette

    private var peak: Int { max(values.max() ?? 0, 1) }

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(index == values.count - 1
                              ? (dimmed ? palette.barIdle : palette.accent)
                              : palette.barIdle)
                        // 值为 0 的日子也留 2pt：断成空白的话，
                        // "这天没有" 和 "这排到此为止" 看起来是一样的。
                        .frame(height: max(proxy.size.height * CGFloat(value) / CGFloat(peak), 2))
                        .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            .frame(height: proxy.size.height, alignment: .bottom)
        }
    }
}

/// UNREAD 那格下半部分的一行：圆点 / 菱形 + 名字 + 数字，整行一个浅填充块。
struct KindRow: View {
    let symbol: AnyView
    let title: String
    let value: Int
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 7) {
            symbol
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(value)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.ink)
        }
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(palette.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 大号那三格统计。
struct StatChip: View {
    let title: String
    let value: Int?
    var tinted = false
    var dimmed = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
            Text(StatusWording.countText(value))
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(tinted ? palette.accent : (dimmed ? palette.muted : palette.ink))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tinted ? palette.accent.opacity(0.10) : palette.fill,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// 值是一段**文字**而不是数字的统计格（iOS 大号的 `Next move-in / in 6d`）。
///
/// 和 ``StatChip`` 分开而不是给它加个 `String?` 重载：那一个吃 `Int?` 并且统一
/// 走 ``StatusWording/countText(_:)`` 把 nil 画成 `—`，那条规矩不该为一个特例松掉。
struct StatChipText: View {
    let title: String
    let value: String
    var dimmed = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(dimmed ? palette.muted : palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// NEWEST 里的一行。
///
/// 第一条的菱形是红的、其余是灰的——设计稿用这一个像素级的差别标出"最新的那条"，
/// 而不是再加一个 `NEW` 标签。
struct ListingRow: View {
    let listing: WidgetListing
    let index: Int
    let now: Date
    /// 中号只放城市，大号放 `城市 · 平台`。
    var longSubtitle = false
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Diamond(color: index == 0 ? palette.accent : palette.pinIdle, size: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(listing.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(longSubtitle ? listing.longSubtitle : listing.shortSubtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(listing.price)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                Text(listing.ageText(at: now))
                    .font(.system(size: 9.5))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        // 设计稿是 33/34。一度收到 30 是为了在 345pt 的大号里排下三条，
        // 现在大号只放两条，回到稿子的数。
        .frame(height: 33)
        .background(index % 2 == 0 ? palette.rowA : palette.rowB,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// 底下那行：绿点 + 「831 live · 4m ago」。
///
/// 绿点是设计稿定义的「抓取在线」。**快照过期时它不能是绿的**——那一刻我们既不
/// 知道抓取在不在线，也不知道 831 还准不准。整句换成 `checked 3h ago`
/// （见 ``WidgetSnapshot/compactFooter(at:)``），点跟着变灰。
struct LiveFooter: View {
    let entry: SnapshotEntry
    /// 带不带前面那个 `831 live`。
    ///
    /// 大号那一格**不带**：它底下已经有一格 `Live now 831`，带上就是同一个数
    /// 在同一张卡上出现两遍——第一次渲染出来就看见了。那一档只说时间，
    /// 走 ``WidgetSnapshot/footnote(at:)``（`scanned 1m ago` / `checked 3h ago`）。
    ///
    /// 设计稿那一行写的是 `synced 1m ago`。这里仍然说 `scanned`——菜单栏、
    /// 统计带、小组件说的都是这个词，为一处再引入第四个动词，正是这轮一直在
    /// 消除的那种漂移。
    var showsCount = true
    @Environment(\.palette) private var palette

    private var isFresh: Bool { entry.snapshot?.isFresh(at: entry.date) ?? false }

    /// 单独成一行，所以首字母提上去（见 ``StatusWording/sentence(_:)``）。
    private var text: String {
        guard let snapshot = entry.snapshot else { return StatusWording.openApp }
        return StatusWording.sentence(showsCount ? snapshot.compactFooter(at: entry.date)
                                                 : snapshot.footnote(at: entry.date))
    }

    var body: some View {
        HStack(spacing: 6) {
            Dot(color: isFresh ? palette.live : palette.pinIdle)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
        }
    }
}

// MARK: - 时间轴

/// `nonisolated`：`Entry` 是 `TimelineProvider` 的关联类型，它要是主 actor 隔离的，
/// 整个 conformance 就跟着被拖过去，provider 那边单独标也没用。
nonisolated struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// `nil` = 共享容器里什么都没有：这台 Mac 还没跑过 app，或者刚登出。
    let snapshot: WidgetSnapshot?
}

/// 三格共用一个 provider：它们读的是**同一份**快照，区别只在画哪几个字段。
nonisolated struct SnapshotProvider: TimelineProvider {

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample)
    }

    /// 图库里那一格的预览。`context.isPreview` 时给示例数据而不是真数据：
    /// 用户还没把它摆上桌面，这时候给一个 `—` 的空格子，看起来就像坏的。
    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let real = WidgetBridge.read()
        completion(SnapshotEntry(date: Date(),
                                 snapshot: context.isPreview ? (real ?? .sample) : real))
    }

    /// 一次给足接下来 24 小时的条目。
    ///
    /// 这几格的文字**自己会变旧**（`4m ago` → `5m ago`、NEWEST 行尾的 `2m` →
    /// `3m`），而 WidgetKit 不会主动重画——每一次该变的时刻都得列在时间轴里。
    /// 具体给哪些时刻见 ``WidgetSnapshot/refreshPoints(from:)``。
    ///
    /// 数据本身在这 24 小时里不会变：这几格不联网，新数据只能由 app 写进来，
    /// 而 app 写完会自己踢一次时间轴（``WidgetBridge/publish(_:)``）。
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetBridge.read()
        let points = (snapshot ?? .placeholder(at: now)).refreshPoints(from: now)
        let entries = points.map { SnapshotEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(24 * 3600))))
    }
}

/// 把调色板灌进去，并铺上纸底。
///
/// **锁屏那三种不铺**：`accessory*` 由系统统一染色，给它一个不透明的纸底只会
/// 得到一块和锁屏壁纸格格不入的方块。那几种自己用 `AccessoryWidgetBackground()`。
struct WidgetSurface<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: () -> Content

    private var isAccessory: Bool {
        #if os(iOS)
        [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
        #else
        false
        #endif
    }

    var body: some View {
        let palette = WidgetPalette.resolve(scheme, skin: .current)
        content()
            .environment(\.palette, palette)
            .environment(\.skin, .current)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(for: .widget) {
                if !isAccessory { palette.paper }
            }
    }
}

/// 未读那个红胶囊。设计稿里它只出现在标题行右端。
struct UnreadPill: View {
    let count: Int
    var label: String?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Text("\(count)")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .monospacedDigit()
            if let label {
                Text(label).font(.system(size: 11))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .frame(minWidth: 17, minHeight: 17)
        .background(palette.accent, in: Capsule())
        .accessibilityLabel("\(count) unread alerts")
    }
}

nonisolated extension WidgetSnapshot {
    /// 图库预览和占位用的示例。数字取自设计稿那张图，一个没改。
    ///
    /// 时间戳现算而不是写死：写死的话预览里那行字会是 `scanned 412d ago`，
    /// 看起来像坏的。
    static var sample: WidgetSnapshot {
        let now = Date()
        let cal = ServerTime.calendar
        let start = cal.startOfDay(for: now)
        let shape = [0, 0, 3, 1, 0, 0, 9, 2, 0, 0, 0, 14, 0, 1,
                     0, 0, 7, 0, 0, 22, 0, 0, 0, 4, 0, 0, 11, 0]
        let days = shape.enumerated().compactMap { offset, total -> MoveInDay? in
            guard let date = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            return MoveInDay(day: MoveInDay.dayKey(date), total: total,
                             bookable: total >= 7 ? max(1, total / 6) : 0)
        }
        let listings = [
            ("Kastanjelaan 400 · Apt 305", "Eindhoven", "Holland2Stay", "€1,142", 2.0),
            ("Vestdijk 24 · Studio 12", "Eindhoven", "Xior", "€898", 14),
            ("Bogert 7 · Apt 118", "Eindhoven", "OurDomain", "€1,280", 41),
        ].enumerated().map { index, row in
            WidgetListing(id: "sample-\(index)", name: row.0, city: row.1, platform: row.2,
                          price: row.3,
                          firstSeen: now.addingTimeInterval(-row.4 * 60).ISO8601Format())
        }
        return WidgetSnapshot(
            newToday: 31,
            dailyNew: [14, 9, 22, 17, 11, 26, 19, 13, 8, 24, 20, 16, 12, 31],
            totalListings: 831,
            statusChanges: 47,
            newThisWeek: 118,
            matchCount: 193,
            isFiltered: true,
            unreadAlerts: 7,
            showsUnread: true,
            newest: listings,
            unreadKinds: UnreadBreakdown(newListings: 3, statusChanges: 2, lottery: 2),
            moveIns: days,
            lastScrape: now.addingTimeInterval(-60).ISO8601Format(),
            capturedAt: now)
    }
}
