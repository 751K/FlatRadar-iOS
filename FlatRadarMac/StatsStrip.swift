import SwiftUI
import FlatRadarCore

/// 列表页顶部的统计带。
///
/// 设计稿 t3「视觉中心」那一轮改的就是这块，原话：
///
/// > 四张等重卡片是"乱"的来源 —— 它们互相竞争，眼睛没有落点。改成一个锚点：
/// > 打开 app 第一眼要看的是"现在有什么新的"，所以 New today 放大到 44px、
/// > 和曲线放进同一个填充块里，占据内容区顶部整条带；总房数、状态变更、平台数
/// > 降级成右侧的小字，不再有各自的容器。
///
/// 所以这里是**一个**块、**一个**大数，不是四个等重的数。
/// 它也不是把 iOS 的 Dashboard 搬过来——docs/DESIGN.md §7.3 写了不做 Mac 版
/// Dashboard，那 1747 行是"一屏看完"的手机成语。
struct StatsStrip: View {

    let summary: SummaryModel
    let listings: ListingsStore

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            anchor
            Sparkline(values: summary.sparkline)
                .frame(width: 248, height: 64)
            Spacer(minLength: 12)
            metrics
        }
        .padding(.horizontal, 18)
        // 设计稿写的是 96。那是按它自己那套小一号的字量的——把字号归到 macOS
        // 字阶之后左边这一列（11pt 标签 + 44pt 数字 + 11pt 说明，连行高约 85pt）
        // 在 96 里只剩上下各 5pt，挤得没有呼吸。120 给到上下各 17pt 左右。
        //
        // 写成**固定**高度而不是 minHeight：`vs. 14-day average` 那行在样本不足
        // 3 天时不显示，高度会跟着塌一截，下面整张表的上沿就跟着跳。
        .frame(height: 120)
        // 靠 4.5% 填充成形，不描边——t2「去线留白」定的规则：
        // 卡片是唯一保留的圆角容器，而它也不画线。
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 锚点：今日新增

    private var anchor: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(StatusWording.newToday)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(StatusWording.countText(summary.newToday))
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .tracking(-1.4)
                    .monospacedDigit()
                if let pct = summary.changeVsBaseline {
                    Text(StatusWording.percent(pct))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        // 涨 = 可选的房源更多，用能效最高档那个深绿；跌用次要色，
                        // **不用红**——房源少不是错误，红色会读成告警。
                        .foregroundStyle(pct >= 0 ? Color.energyTop : Color.secondary)
                }
            }
            .padding(.top, 2)
            if let base = summary.baselineAverage {
                Text(StatusWording.vsBaseline(base))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
        }
    }

    // MARK: - 右侧三个小数

    /// ⚠️ 左边两个是**全库**的，第三个是**这个账号筛出来的**，可以差很多
    /// （实测：库里 828 条，账号的 listing_filter 只匹配 80 条）。标签把口径写在脸上。
    private var metrics: some View {
        HStack(alignment: .top, spacing: 30) {
            metric(StatusWording.totalListings,
                   value: summary.summary?.total,
                   caption: String(localized: "all platforms"))
            metric(StatusWording.statusChanges,
                   value: summary.summary?.changes24h,
                   caption: String(localized: "last 24h"))
            // 原先没套筛选时这里写的是 `Showing`，而菜单栏同一个数写的是
            // `Listings`——同一台机器上两个名字。统一到 ``StatusWording``。
            metric(StatusWording.countLabel(isFiltered: listings.isFiltered),
                   value: listings.total > 0 ? listings.total : nil,
                   caption: loadCaption)
        }
        .fixedSize()
    }

    private func metric(_ title: String, value: Int?, caption: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(StatusWording.countText(value))
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .padding(.top, 2)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
            }
        }
    }

    /// 分页没拉完时**必须说出来**——否则用户会以为排序和筛选覆盖的是全部房源。
    private var loadCaption: String? {
        if listings.loadMoreFailed {
            return String(localized: "only \(listings.listings.count) loaded")
        }
        if listings.hasMore {
            return String(localized: "\(listings.listings.count) loaded…")
        }
        let n = Set(listings.listings.compactMap(\.source)).count
        guard n > 0 else { return nil }
        return n == 1
            ? String(localized: "from \(n) platform")
            : String(localized: "from \(n) platforms")
    }
}

/// 极简折线：一条线 + 线下的向下淡出 + 一个端点。
///
/// 没有坐标轴、没有网格、没有图例——t2「去线留白」把这条也写进规则了
/// （「曲线只画一条线加一个当前点，不画坐标轴和网格，符合去线的规则」）。
///
/// 和 iOS 那条曲线**逐项对齐**
/// -------------------------
/// 两端画的是同一件事（每日新增），不该长得像两个图表。对照 `DashboardView`
/// 里的 `Sparkline` / `SparklineView`：
///
/// | | 值 | 出处 |
/// |---|---|---|
/// | 颜色 | ``Theme/chart`` | iOS `SparklineView.tint` 的默认值 `.blue` |
/// | 线宽 | 2.5，圆头圆角 | 同 iOS |
/// | 线下填充 | 同色 0.28 → 0.02 向下淡出 | 同 iOS |
/// | 上下余量 | 4 | 同 iOS |
/// | 纵向归一 | min–max，不从 0 起 | 同 iOS |
/// | 插值 | 单调三次 Hermite | 同 iOS（这一条是把 Mac 的做法搬过去的，见下） |
///
/// **还剩一处不一样**：端点那个实心圆，iOS 没有。留着是因为 Mac 这条线 248pt 宽、
/// 横在统计带正中，需要一个"这一头是今天"的落点；iOS 那条 130pt 夹在卡片里，
/// 大数字就贴在旁边。要去掉的话删下面那个 `Circle` 即可。
///
/// 不用 Swift Charts：那要带一整个框架进来，而这里画的是一条折线。
struct Sparkline: View {

    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if values.count >= 2 {
                    SparklineShape(values: values, closed: true)
                        .fill(LinearGradient(
                            colors: [Theme.chart.opacity(0.28), Theme.chart.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                    SparklineShape(values: values)
                        .stroke(Theme.chart,
                                style: StrokeStyle(lineWidth: 2.5,
                                                   lineCap: .round,
                                                   lineJoin: .round))
                    // 端点：告诉眼睛「这一头是今天」。iOS 没有这一笔。
                    if let last = SparklineShape.points(values, in: proxy.size).last {
                        Circle()
                            .fill(Theme.chart)
                            .frame(width: 6.4, height: 6.4)
                            .position(last)
                    }
                }
            }
        }
        // 数值已经在旁边写出来了，读屏不必再念一遍趋势。
        .accessibilityHidden(true)
    }
}

/// 曲线本身。
///
/// 拆成 `Shape` 而不是在 `View` 里各画一遍：填充和描边必须是**同一条**曲线，
/// 分开算迟早分叉，填充的上沿就会和线错开一条缝。iOS 那边用的是同一招
/// （`Sparkline(data:closed:)`）。
///
/// `nonisolated`：`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 会把这个类型也放到
/// 主 actor 上，而 `Shape.path(in:)` 要求 nonisolated——Xcode 27 起这条不匹配
/// 从警告升级成错误（#ConformanceIsolation）。路径计算是纯函数，不碰任何状态。
nonisolated struct SparklineShape: Shape {

    let values: [Double]

    /// `true` 时把曲线闭合到框底，用来画线下的填充。
    var closed = false

    /// 上下各留的余量，免得线宽把峰谷削平。和 iOS 一样是 4。
    static let inset: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        let pts = Self.points(values, in: rect.size)
        guard pts.count >= 2 else { return Path() }
        var p = Path()
        p.move(to: pts[0])
        Self.appendCurve(to: &p, pts)
        if closed {
            p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: rect.maxY))
            p.addLine(to: CGPoint(x: pts[0].x, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }

    /// 纵向按 **min–max** 归一，不是从 0 算起：迷你趋势线没有坐标轴，只表达
    /// **形状**，量级由旁边那个大数字负责。和 iOS 同一套算法。
    static func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let span = hi - lo
        let stepX = size.width / CGFloat(values.count - 1)
        let usable = max(size.height - inset * 2, 1)
        return values.enumerated().map { i, v in
            // 全平（每天都一样）时不要除以零，画成一条居中的直线。
            let ratio = span > 0 ? (v - lo) / span : 0.5
            return CGPoint(x: CGFloat(i) * stepX,
                           y: inset + usable * (1 - CGFloat(ratio)))
        }
    }

    /// 把折线画成平滑曲线，用**单调三次 Hermite**（Fritsch–Carlson）。
    ///
    /// 为什么不用普通的 Catmull-Rom
    /// --------------------------
    /// 那种样条会**过冲**：两个低点之间夹一个高点时，曲线会在低点外侧甩出去，
    /// 画出一个比当天实际值还低的谷。这条线画的是「每天新增几套」，
    /// 过冲等于**画出了一个从来没发生过的数字**——而且下面还铺了填充，
    /// 甩到基线以下会直接穿帮。
    ///
    /// 单调三次插值的性质就是：数据没有的峰谷，曲线也不会造出来。
    /// 代价是转折处比 Catmull-Rom 稍微"硬"一点点，在这个尺寸上看不出来。
    ///
    /// iOS 原来用的是夹住控制点的 Catmull-Rom（夹的是**画布边界**，挡得住甩出框，
    /// 挡不住框内那些凭空多出来的鼓包）。对齐画法时把这套搬了过去，两端现在同一份。
    /// `FlatRadarMacTests` 和 `FlatRadarTests` 里各有一条测试钉住"不许造峰谷"。
    static func appendCurve(to path: inout Path, _ pts: [CGPoint]) {
        guard pts.count > 2 else {
            for pt in pts.dropFirst() { path.addLine(to: pt) }
            return
        }

        let n = pts.count
        // 相邻两点的斜率。x 是等距的，所以 h 是常数。
        let h = pts[1].x - pts[0].x
        var d = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (pts[i + 1].y - pts[i].y) / h }

        // 端点取单侧斜率，中间取两侧平均。
        var m = [CGFloat](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = (d[i - 1] + d[i]) / 2 }

        // Fritsch–Carlson：把切线收进不会过冲的范围里。
        for i in 0..<(n - 1) {
            if d[i] == 0 {
                // 这一段是平的，两端切线也必须是平的，否则会鼓出一个包。
                m[i] = 0
                m[i + 1] = 0
                continue
            }
            var a = m[i] / d[i]
            var b = m[i + 1] / d[i]
            // 切线和这一段的割线**反向** = 这个点是局部极值（左右两段一升一降），
            // 切线必须压平。不压的话曲线会冲过这个端点，画出一个比当天实际值
            // 更极端的峰或谷——正是这套插值本来要防的那件事。
            //
            // 这一步漏过一次：只处理了 d == 0，没处理反号。`[1, 5, 5, 1, 9]` 在
            // 索引 3（那个 1）上就会冲出去，控制点落到 49.5 而该段只到 46。
            // 两端的 SparklineCurveTests 钉的就是它。
            if a < 0 { m[i] = 0; a = 0 }
            if b < 0 { m[i + 1] = 0; b = 0 }
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / sqrt(s)
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }

        // Hermite 切线换算成三次贝塞尔的控制点：距端点 h/3，斜率就是切线。
        for i in 0..<(n - 1) {
            let c1 = CGPoint(x: pts[i].x + h / 3, y: pts[i].y + m[i] * h / 3)
            let c2 = CGPoint(x: pts[i + 1].x - h / 3, y: pts[i + 1].y - m[i + 1] * h / 3)
            path.addCurve(to: pts[i + 1], control1: c1, control2: c2)
        }
    }
}
