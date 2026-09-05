import SwiftUI
import UIKit

/// 把 UIKit 的 ``UICalendarView`` 包进 SwiftUI。
///
/// 为什么不继续手写
/// ----------------
/// 手写版为了"跟手翻页"调了三轮：预计算格子、锁手势轴、拖动时降级渲染。每一轮都
/// 修掉了一个真实问题，但都没能追平系统的手感——原生那套滑动、回弹、跨月惯性是
/// 苹果调了很多年的，再往下调是在重造轮子。
///
/// 换过来直接拿到的：左右滑动切换月份、跨月的选中态动画、本地化（周首日、月份名、
/// 日历体系）、Dynamic Type、VoiceOver 的日期朗读、深色模式。这些手写版每一样都
/// 要自己维护。
///
/// 代价
/// ----
/// 装饰只能是日期数字**下方**的一个小标记（点 / 图标 / 自定义 view），尺寸只有
/// 三档。手写版是把房源数直接排在日期下面、有房源的格子还有一层淡色底——那种
/// 信息密度在这里做不到。这里用自定义 view 塞一个数字，位置和大小都由系统定。
///
/// 另外它是 UIKit 视图，项目里 `liquidGlass` 那套统一质感在它内部用不上。
struct NativeMonthCalendar: UIViewRepresentable {

    @Binding var selectedDay: Date?
    /// 当前显示的月份（该月第一天）。用户滑动时由 delegate 回写。
    @Binding var visibleMonth: Date
    /// 可选月份的范围。超出的月份系统会自己灰掉、划不过去。
    let availableRange: (start: Date, end: Date)?
    /// 某天有多少套房源。只用来画装饰。
    let countForDay: (Date) -> Int

    private static let cal = Calendar.current

    /// 返回的是一个**容器**，`UICalendarView` 用 Auto Layout 钉在里面。
    ///
    /// 文档明写着「Set up Auto Layout to position the calendar view in your
    /// interface」——它要求用约束布局。而 UIViewRepresentable 默认是 SwiftUI
    /// 直接设 frame（autoresizing mask），内部的分页布局在那种方式下算不对：
    /// 表现就是左右两侧透出相邻月份的日期。
    ///
    /// 之前以为是"给太宽了"，靠调宽度上限压下去（420 干净、640 露馅），那只是
    /// 让它恰好落回能算对的尺寸，没解决根因——所以换个设备或字号又会露出来。
    func makeUIView(context: Context) -> UIView {
        let container = UIView()

        let view = UICalendarView()
        view.calendar = Self.cal
        view.locale = .autoupdatingCurrent
        view.fontDesign = .rounded
        view.wantsDateDecorations = true
        view.delegate = context.coordinator
        view.tintColor = UIColor(Color.accentColor)

        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        view.selectionBehavior = selection
        context.coordinator.selection = selection
        context.coordinator.calendarView = view

        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.calendarView else { return }

        if let range = availableRange {
            let interval = Self.monthSpan(range)
            if view.availableDateRange != interval { view.availableDateRange = interval }
        }

        // **只响应外部发起的月份变化**（比如工具栏那个 Today 按钮），不要把用户
        // 自己滑出来的月份再设回去。
        //
        // 用户滑动时 `didChangeVisibleDateComponentsFrom` 会在过程中就报出新月份，
        // 我们写进 `visibleMonth` → SwiftUI 重跑 updateUIView → 如果这里再调一次
        // `setVisibleDateComponents(animated:)`，就打断了正在进行的那次滑动。
        // 表现就是"滑起来乱飘"：手指还在动，视图被程序拽去另一个位置。
        if context.coordinator.lastReportedMonth != visibleMonth {
            let wanted = Self.cal.dateComponents([.year, .month], from: visibleMonth)
            let current = view.visibleDateComponents
            if current.year != wanted.year || current.month != wanted.month {
                view.setVisibleDateComponents(wanted, animated: true)
            }
        }

        // `setSelected` 会**把日历滚到选中日所在的月份**（头文件原话：
        // "Sets the selected date to be displayed in the calendar"）。所以这里
        // 多调一次不是白调，是会把用户刚翻到的月份拽回去——判等必须准。
        let wantedSelection = selectedDay.map {
            Self.cal.dateComponents([.year, .month, .day], from: $0)
        }
        if !Self.isSameDay(context.coordinator.selection?.selectedDate, wantedSelection) {
            context.coordinator.selection?.setSelected(wantedSelection, animated: true)
        }

        // 数据变了要重画装饰。整月重载，不逐日 diff：一个月 30 格，diff 的成本
        // 比直接重载还高。
        if context.coordinator.decorationsToken != decorationsToken {
            context.coordinator.decorationsToken = decorationsToken
            view.reloadDecorations(forDateComponents: visibleMonthDays(), animated: true)
        }
    }

    /// 宽度卡在日历**自己愿意的**那个值上，高度交给 Auto Layout 算。
    ///
    /// UICalendarView 内部是一个分页滚动视图，每一页是一个月的网格，而**网格有
    /// 自己的最大宽度**。视图比那个宽度宽出来的部分，会被相邻月份的页填满——
    /// 屏幕上就是左右各露出几列灰色日期。
    ///
    /// 这一点文档里没写，是从现象推的：卡片 880pt 宽时，中间那个月只占约 500pt，
    /// 两侧各露三列。加 Auto Layout 约束（文档要求的那一条）也压不住，因为分页
    /// 视图本来就该铺满自己的容器，问题在网格不跟着铺。
    ///
    /// 所以不能把外面给的宽度照单全收，要先问它压缩后想要多宽。问不出来才退回
    /// 常量——那个常量取自实测：420 干净、640 露馅。
    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView container: UIView,
                      context: Context) -> CGSize? {
        guard let offered = proposal.width, offered > 0 else { return nil }
        let width = min(offered, Self.preferredWidth(of: container))
        let fitted = container.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: width, height: fitted.height)
    }

    /// 实测：420 干净，640 会露出相邻月份。问不出固有宽度时用这个。
    private static let fallbackMaxWidth: CGFloat = 460

    private static func preferredWidth(of container: UIView) -> CGFloat {
        let compressed = container.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize).width
        // 压缩尺寸有时会退化成 0 或一个很小的值（约束还没生效），那种时候别用。
        return compressed > 320 ? compressed : fallbackMaxWidth
    }

    /// 只比 年 / 月 / 日 三个字段。
    ///
    /// 不能直接用 `DateComponents ==`——它把 `calendar` / `timeZone` / `era` /
    /// `isLeapMonth` 这些也一并比进去。用户点一下日期，UIKit 写回
    /// `selection.selectedDate` 的那份组件是**带 calendar 和 timeZone 的**，
    /// 而我们这边是 `dateComponents([.year,.month,.day])` 现造的，那几个字段
    /// 全是 nil。两边指的是同一天，`!=` 却永远为真。
    ///
    /// 后果是每次 `updateUIView` 都会重设一次选中态，而重设会滚回选中日那个月：
    /// 用户点「下一月」→ delegate 回写 `visibleMonth` → SwiftUI 更新 →
    /// 这里把视图拽回九月。第二次点才成，是因为那时 `visibleMonth` 已经是十月了，
    /// delegate 不再回写，也就不再触发这次更新。
    static func isSameDay(_ a: DateComponents?, _ b: DateComponents?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.year == b.year && a.month == b.month && a.day == b.day
    }

    /// 把数据范围**摊到整月**，再并进今天所在的月。
    ///
    /// 直接拿首尾两个房源日期当范围有两个毛病：
    ///
    /// - 边界月只开一半。数据从 9/20 开始的话，9/1–9/19 全是灰的，翻不进去也点不了。
    /// - 头文件写着「`visibleDateComponents` must also be a valid date within
    ///   `availableDateRange`」。而初始 `visibleMonth` 和工具栏「Today」按钮
    ///   都指向**今天所在的月**——数据要是从下个月才开始，那个月份就是非法值。
    static func monthSpan(_ range: (start: Date, end: Date)) -> DateInterval {
        let today = Date()
        let lo = min(range.start, range.end, today)
        let hi = max(range.start, range.end, today)
        let start = startOfMonth(lo)
        // 末月的最后一秒：下个月月初往回退 1 秒。
        let end = cal.date(byAdding: DateComponents(month: 1, second: -1),
                           to: startOfMonth(hi)) ?? hi
        return DateInterval(start: start, end: max(end, start))
    }

    static func startOfMonth(_ date: Date) -> Date {
        cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }

    /// 数据指纹：变了就重画装饰。
    var decorationsToken: Int {
        visibleMonthDays().reduce(into: 0) { acc, comps in
            acc = acc &* 31 &+ (Self.cal.date(from: comps).map(countForDay) ?? 0)
        }
    }

    private func visibleMonthDays() -> [DateComponents] {
        guard let range = Self.cal.range(of: .day, in: .month, for: visibleMonth) else { return [] }
        return range.compactMap { d in
            Self.cal.date(byAdding: .day, value: d - 1, to: visibleMonth).map {
                Self.cal.dateComponents([.year, .month, .day], from: $0)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UICalendarViewDelegate,
                             UICalendarSelectionSingleDateDelegate {
        var parent: NativeMonthCalendar
        var selection: UICalendarSelectionSingleDate?
        /// makeUIView 返回的是容器，真正的日历视图存在这里。
        weak var calendarView: UICalendarView?
        var decorationsToken = Int.min
        /// delegate 最后一次报上来的可见月份。用来区分"用户滑出来的"和"外部设的"。
        var lastReportedMonth: Date?

        init(parent: NativeMonthCalendar) { self.parent = parent }

        func calendarView(_ calendarView: UICalendarView,
                          decorationFor dateComponents: DateComponents)
        -> UICalendarView.Decoration? {
            guard let date = NativeMonthCalendar.cal.date(from: dateComponents) else { return nil }
            let count = parent.countForDay(date)
            guard count > 0 else { return nil }
            // 自定义 view 而不是彩色圆点：圆点只说明"这天有房"，数字才说明有几套，
            // 而"几套"正是这一屏要回答的问题。
            return .customView {
                let label = UILabel()
                label.text = "\(count)"
                label.font = .systemFont(ofSize: 11, weight: .semibold)
                label.textColor = UIColor(Color.accentColor)
                label.textAlignment = .center
                return label
            }
        }

        func calendarView(_ calendarView: UICalendarView,
                          didChangeVisibleDateComponentsFrom previous: DateComponents) {
            let comps = calendarView.visibleDateComponents
            guard let date = NativeMonthCalendar.cal.date(from: comps) else { return }
            let start = NativeMonthCalendar.cal.date(
                from: NativeMonthCalendar.cal.dateComponents([.year, .month], from: date)) ?? date
            lastReportedMonth = start
            if start != parent.visibleMonth { parent.visibleMonth = start }
            // 选中日不在新月份里就清掉。右栏列的是「选中那天的房源」，留着就会
            // 出现月历显示十月、右栏还列着九月某天的怪状态。手写版翻页时也是
            // 这么做的（`shiftMonth` 结尾 `selectedDay = nil`）。
            if let day = parent.selectedDay,
               !NativeMonthCalendar.cal.isDate(day, equalTo: start, toGranularity: .month) {
                parent.selectedDay = nil
            }
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate,
                           didSelectDate dateComponents: DateComponents?) {
            parent.selectedDay = dateComponents.flatMap { NativeMonthCalendar.cal.date(from: $0) }
        }
    }
}
