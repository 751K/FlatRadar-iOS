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
            Text("New today")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(summary.newToday.map(String.init) ?? "—")
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .tracking(-1.4)
                    .monospacedDigit()
                if let pct = summary.changeVsBaseline {
                    Text(pct >= 0 ? "+\(pct)%" : "\(pct)%")
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        // 涨 = 可选的房源更多，用能效最高档那个深绿；跌用次要色，
                        // **不用红**——房源少不是错误，红色会读成告警。
                        .foregroundStyle(pct >= 0 ? Color.energyTop : Color.secondary)
                }
            }
            .padding(.top, 2)
            if let base = summary.baselineAverage {
                Text("vs. 14-day average of \(base)")
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
            metric("Total listings",
                   value: summary.summary?.total,
                   caption: "all platforms")
            metric("Status changes",
                   value: summary.summary?.changes24h,
                   caption: "last 24h")
            metric(listings.isFiltered ? "Matching filters" : "Showing",
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
            Text(value.map(String.init) ?? "—")
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
        if listings.loadMoreFailed { return "only \(listings.listings.count) loaded" }
        if listings.hasMore { return "\(listings.listings.count) loaded…" }
        let n = Set(listings.listings.compactMap(\.source)).count
        return n > 0 ? "from \(n) platform\(n == 1 ? "" : "s")" : nil
    }
}

/// 极简折线：一条线 + 线下的淡填充 + 一个端点。
///
/// 没有坐标轴、没有网格、没有图例——t2「去线留白」把这条也写进规则了
/// （「曲线只画一条线加一个当前点，不画坐标轴和网格，符合去线的规则」）。
///
/// 不用 Swift Charts：那要带一整个框架进来，而这里画的是一条折线。
struct Sparkline: View {

    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let pts = points(in: proxy.size)
            ZStack {
                if pts.count >= 2 {
                    area(pts, height: proxy.size.height)
                        .fill(Color.primary.opacity(0.05))
                    line(pts)
                        .stroke(Theme.ink,
                                style: StrokeStyle(lineWidth: 1.8,
                                                   lineCap: .round,
                                                   lineJoin: .round))
                    // 端点：告诉眼睛「这一头是今天」。
                    Circle()
                        .fill(Theme.ink)
                        .frame(width: 6.4, height: 6.4)
                        .position(pts[pts.count - 1])
                }
            }
        }
        // 数值已经在旁边写出来了，读屏不必再念一遍趋势。
        .accessibilityHidden(true)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let span = hi - lo
        let stepX = size.width / CGFloat(values.count - 1)
        let inset: CGFloat = 2.5
        let usable = max(size.height - inset * 2, 1)
        return values.enumerated().map { i, v in
            // 全平（每天都一样）时不要除以零，画成一条居中的直线。
            let ratio = span > 0 ? (v - lo) / span : 0.5
            return CGPoint(x: CGFloat(i) * stepX,
                           y: inset + usable * (1 - CGFloat(ratio)))
        }
    }

    private func line(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.move(to: pts[0])
        appendCurve(to: &p, pts)
        return p
    }

    private func area(_ pts: [CGPoint], height: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: pts[0].x, y: height))
        p.addLine(to: pts[0])
        appendCurve(to: &p, pts)
        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: height))
        p.closeSubpath()
        return p
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
    /// 代价是转折处比 Catmull-Rom 稍微"硬"一点点，在 248×52 这个尺寸上看不出来。
    private func appendCurve(to path: inout Path, _ pts: [CGPoint]) {
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
            let a = m[i] / d[i]
            let b = m[i + 1] / d[i]
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
