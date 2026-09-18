import SwiftUI
import Charts
import FlatRadarCore

/// Stats 屏：一次把十二张图全铺开。
///
/// 为什么不照搬 iOS 的 Dashboard
/// ---------------------------
/// iOS 那边是七张 mini 卡 + 点开看 sheet。**"点开看大图"本身就是手机的妥协**——
/// 屏幕放不下才要钻进去。Mac 的优势正是一次看全，照搬等于把一个为小屏做的
/// 折中原样搬到大屏上。
///
/// docs/DESIGN.md §6 对此也有明确一条：
///
/// > Hero 大数字卡 + 横滑 chip 排 ❌ **手机成语** —— Mac 上横向滚动条是失败信号；
/// > 大数字卡在 1400pt 宽里是浪费
///
/// 所以这里没有大数字卡、没有横滑、没有 sheet。取而代之：
///
/// - 全部图一屏铺开，按窗口宽度自动分列
/// - 两张时序图**跨整行**（31 个点压进三分之一宽会挤成一团）
/// - 点一张图 → **右栏出完整明细**（标签 / 数量 / 占比）。左边看形状、右边看数字，
///   顺便用上"多屏共用 inspector"这个 Mac 版的主要收益
///
/// 卡里只画前若干条（城市有 20 个），长尾留给右栏——这正是那个分工的意义。
struct StatsPane: View {

    @Bindable var model: BrowseModel
    let stats: StatsModel

    /// 一列最少多宽。
    ///
    /// 320 是按**最挤的那张**定的：`price_dist` 有 9 根柱子加 9 个区间标签，
    /// 再窄柱子就细得看不出高度差、标签也糊成一条灰带。
    private static let minColumnWidth: CGFloat = 320
    private static let gridSpacing: CGFloat = 14

    /// 网格实际有多宽。**自己量，不用 `GridItem(.adaptive:)`。**
    ///
    /// `.adaptive(minimum: 280)` 实测排出了**五列 223pt** ——比下限还窄 57pt。
    /// 原因是它拿到的提议宽度和最终落位的宽度不是一回事（这一屏外面套着
    /// `ScrollView` 和 `NavigationSplitView` 的 detail 栏），它按提议的宽度算
    /// 列数，然后被真实宽度挤扁。
    ///
    /// 自己量就没有这个偏差：量到多少就是多少。`MainWindow` 和 `MapPane`
    /// 也都是这么处理宽度的。
    @State private var gridWidth: CGFloat = 0

    private var columns: [GridItem] {
        let usable = max(gridWidth, Self.minColumnWidth)
        let count = max(1, Int((usable + Self.gridSpacing)
                               / (Self.minColumnWidth + Self.gridSpacing)))
        return Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing),
                     count: count)
    }

    var body: some View {
        content
            .task { await stats.load() }
            // 换了时间窗、新数据落地之后，右栏那张图的明细也要换成新窗的。
            //
            // `StatsSelection` 存的是**整份数据**（见它的注释），不会自己跟着变。
            // 不补这一步的话，左边图已经是 7 天，右栏还在列 30 天的数字。
            .onChange(of: stats.chartsWindow) { _, _ in
                guard let chart = model.statsChart else { return }
                if let entries = stats.charts[chart.key], !entries.isEmpty {
                    model.statsChart = StatsSelection(key: chart.key, title: chart.title,
                                                      entries: entries)
                } else {
                    model.statsChart = nil
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if stats.isLoading && stats.charts.isEmpty {
            centered { ProgressView("Loading stats…") }
        } else if stats.failed && stats.charts.isEmpty {
            centered { loadFailure }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    // 时序图跨整行：31 个点在三分之一宽里读不出形状。
                    ForEach(StatsModel.keys.filter(isWide), id: \.self) { key in
                        card(key)
                    }
                    LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                        ForEach(StatsModel.keys.filter { !isWide($0) }, id: \.self) { key in
                            card(key)
                        }
                    }
                }
                .padding(16)
            }
            // 量的是**滚动视图**，不是网格自己。
            //
            // 量网格会形成一个环：列数由 `gridWidth` 决定 → 网格按列数布局 →
            // 量出来的又是 `gridWidth`。SwiftUI 检测到这种循环就不再往下传，
            // 实测卡在"五列 235pt"上（比下限窄 85pt）不动了。
            // 滚动视图的宽度和列数无关，量它没有环。
            .background {
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    gridWidth = $0 - 32   // 两侧各 16 的内边距
                }
            }
        }
    }

    private func isWide(_ key: String) -> Bool {
        key == "daily_new" || key == "daily_changes"
    }

    // MARK: - 顶部

    /// **这段话是必需的，不是装饰。**
    ///
    /// 后端每张图都按 `first_seen` 过滤，所以整屏说的是"过去 N 天**新上架**的
    /// 那批房源"，不是库存。不写的话「Eindhoven 119」会被读成"现在有 119 套"，
    /// 而库存其实是 892 套、其中 Eindhoven 远不止这个数。
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.title2.weight(.semibold))
                    .tracking(-0.25)
                // ⚠️ **字面量，不能拼接。** SwiftUI 只对字符串字面量解析 Markdown，
                // 用 `+` 拼出来的 `String` 会把 `**` 原样画在屏幕上——第一版就是
                // 拼的，实拍出来是「counts listings **first seen** in this window」。
                Text("Everything below counts listings **first seen** in this window — not what is in stock right now.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // 换窗之后、新数据回来之前，屏上还是上一个窗的图。给个"在取"的信号，
            // 标题那边则照实写旧窗（见 `headline`）。
            if stats.isLoading, !stats.charts.isEmpty {
                ProgressView().controlSize(.small)
            }
            Picker("", selection: Binding(get: { stats.days },
                                          set: { stats.days = $0 })) {
                ForEach(StatsModel.Window.allCases) { w in
                    Text(w.label).tag(w)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
        .padding(.bottom, 2)
    }

    /// 按**屏上这批数据所属的窗**写，不按 Picker 当前选的写：两者在换窗的那一小段
    /// 时间里不相等，照 Picker 写就是在 30 天的数字上标"最近 7 天"。
    private var headline: String {
        let n = stats.sampleSize
        let window = (stats.chartsWindow ?? stats.days).rawValue
        guard n > 0 else { return String(localized: "Last \(window) days") }
        if n == 1 {
            return String(localized: "\(n) listing in the last \(window) days")
        }
        return String(localized: "\(n) listings in the last \(window) days")
    }

    // MARK: - 一张图

    @ViewBuilder
    private func card(_ key: String) -> some View {
        if let entries = stats.charts[key], !entries.isEmpty {
            ChartCard(key: key,
                      title: StatsCopy.title(key),
                      caption: StatsCopy.caption(key),
                      entries: entries,
                      isSelected: model.statsChart?.key == key,
                      wide: isWide(key)) {
                model.statsChart = StatsSelection(key: key,
                                                  title: StatsCopy.title(key),
                                                  entries: entries)
            }
        }
    }

    // MARK: - 空状态

    private var loadFailure: some View {
        ContentUnavailableView {
            Label("Unable to Load Stats", systemImage: "chart.bar.xaxis")
        } description: {
            Text("The public stats endpoints didn’t answer. They don’t need a sign-in, so this is usually the server or the network.")
        } actions: {
            Button("Try Again") { Task { await stats.load(force: true) } }
        }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 文案

/// 每张图叫什么、副标题说什么。
///
/// 副标题**只写数据本身不会说的那句话**。「By city」下面写"Top 8, full list on
/// the right"是有用的（它解释了为什么只有 8 条）；写"房源在各城市的分布"
/// 是把标题重复一遍。
nonisolated enum StatsCopy {

    static func title(_ key: String) -> String {
        switch key {
        case "daily_new":     return String(localized: "New per day")
        case "daily_changes": return String(localized: "Status changes per day")
        case "status_dist":   return String(localized: "Where they are now")
        case "price_dist":    return String(localized: "Rent")
        case "area_dist":     return String(localized: "Size")
        case "type_dist":     return String(localized: "Type")
        case "energy_dist":   return String(localized: "Energy label")
        case "floor_dist":    return String(localized: "Floor")
        case "city_dist":     return String(localized: "City")
        case "source_dist":   return String(localized: "Platform")
        case "tenant_dist":   return String(localized: "Tenant type")
        case "hourly_dist":   return String(localized: "When they appear")
        default:              return key
        }
    }

    static func caption(_ key: String) -> String? {
        switch key {
        case "status_dist":
            // 这张图最容易被误读成"库存状态"。它其实在回答一个更有意思的问题：
            // 这批新房源多快没的。
            return String(localized: "How much of this batch is already gone")
        case "city_dist":
            return String(localized: "Top 8 — full list on the right")
        case "hourly_dist":
            return String(localized: "Local time, when the platform published them")
        case "daily_changes":
            return String(localized: "A listing can change more than once a day")
        default:
            return nil
        }
    }

    /// 卡里画几条。剩下的在右栏。
    ///
    /// 城市有 20 个、房型合并后 4–5 个——一刀切"画前 8 条"会让只有 3 条的图
    /// 下面空一块。所以只有真的长的那几张才截。
    static func cardLimit(_ key: String) -> Int {
        key == "city_dist" ? 8 : .max
    }
}
