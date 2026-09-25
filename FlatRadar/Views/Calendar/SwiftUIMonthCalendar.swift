import SwiftUI
import FlatRadarCore

/// Expandable month grid implemented entirely in SwiftUI.
///
/// Each month is a full-width scroll target. iOS 18 scroll APIs provide interactive
/// paging and settling; swiped months are published only after scrolling settles.
struct SwiftUIMonthCalendar: View {
    @Binding var selectedDay: Date?
    @Binding var visibleMonth: Date
    let availableRange: (start: Date, end: Date)?
    let countForDay: (Date) -> Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var minimumCellHeight: CGFloat = 48
    @State private var measuredWidth: CGFloat = 0

    @State private var scrollMonth: Date?
    @State private var scrollPhase: ScrollPhase = .idle

    init(selectedDay: Binding<Date?>, visibleMonth: Binding<Date>,
         availableRange: (start: Date, end: Date)?,
         countForDay: @escaping (Date) -> Int) {
        _selectedDay = selectedDay
        _visibleMonth = visibleMonth
        self.availableRange = availableRange
        self.countForDay = countForDay
        _scrollMonth = State(initialValue: CalendarDateMath.startOfMonth(visibleMonth.wrappedValue))
    }

    private var calendarWidth: CGFloat { max(0, measuredWidth - 24) }

    private var cellHeight: CGFloat {
        let cellWidth = max(0, (calendarWidth - MonthCalendarLayout.columnSpacing * 6) / 7)
        return min(minimumCellHeight * 1.55, max(minimumCellHeight, cellWidth * 0.82))
    }

    private var gridHeight: CGFloat {
        CGFloat(MonthCalendarLayout.rowCount) * cellHeight
            + CGFloat(MonthCalendarLayout.rowCount - 1) * MonthCalendarLayout.rowSpacing
    }

    private var months: [Date] {
        CalendarDateMath.months(in: availableRange, fallback: visibleMonth)
    }

    var body: some View {
        VStack(spacing: 10) {
            monthHeader
            weekdayHeader
            monthPager
                .frame(height: gridHeight)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .onChange(of: visibleMonth) { _, month in
            scroll(to: month)
        }
        .onChange(of: months, initial: true) { _, validMonths in
            reconcileRange(validMonths)
        }
    }

    private var monthPager: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(months, id: \.self) { month in
                    MonthCalendarPage(month: month, selectedDay: selectedDay,
                                      cellHeight: cellHeight, countForDay: countForDay) { day in
                        publishMonth(CalendarDateMath.startOfMonth(day))
                        selectedDay = day
                    }
                    .containerRelativeFrame(.horizontal)
                    .id(month)
                }
            }
            .scrollTargetLayout()
        }
        // Full-width targets give page snapping; alwaysByOne (iOS 18) also keeps
        // a fast flick from skipping several months on regular-width screens.
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollPosition(id: $scrollMonth, anchor: .center)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("calendar.monthPager")
        .onScrollPhaseChange { _, phase in
            scrollPhase = phase
            if phase == .idle { publishSettledMonth() }
        }
        .onChange(of: scrollMonth) { _, _ in
            // Also handles nonanimated jumps (Reduce Motion) and initial positioning.
            if scrollPhase == .idle { publishSettledMonth() }
        }
    }

    private var monthHeader: some View {
        HStack(spacing: 8) {
            monthButton(direction: -1, symbol: "chevron.left", label: "Previous month")

            Text(MonthCalendarLayout.monthTitleFormatter.string(from: visibleMonth))
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("calendar.monthTitle")

            monthButton(direction: 1, symbol: "chevron.right", label: "Next month")
        }
    }

    private func monthButton(direction: Int, symbol: String, label: LocalizedStringKey) -> some View {
        Button {
            changeMonth(direction)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .liquidGlass(Circle(), interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(!canChangeMonth(direction))
        .accessibilityLabel(label)
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: MonthCalendarLayout.columns, spacing: MonthCalendarLayout.columnSpacing) {
            ForEach(Array(MonthCalendarLayout.weekdaySymbols.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }
        }
    }

    private func canChangeMonth(_ delta: Int) -> Bool {
        guard let target = MonthCalendarLayout.calendar.date(byAdding: .month, value: delta,
                                                            to: visibleMonth) else { return false }
        return months.contains(CalendarDateMath.startOfMonth(target))
    }

    private func changeMonth(_ delta: Int) {
        guard canChangeMonth(delta),
              let target = MonthCalendarLayout.calendar.date(byAdding: .month, value: delta,
                                                            to: visibleMonth) else { return }
        publishMonth(CalendarDateMath.startOfMonth(target))
        scroll(to: target)
    }

    private func scroll(to date: Date) {
        let month = CalendarDateMath.startOfMonth(date)
        guard months.contains(month), scrollMonth != month else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            scrollMonth = month
        }
    }

    private func publishSettledMonth() {
        guard let month = scrollMonth, months.contains(month) else { return }
        publishMonth(month)
    }

    private func publishMonth(_ month: Date) {
        if visibleMonth != month { visibleMonth = month }
        if let selectedDay,
           !MonthCalendarLayout.calendar.isDate(selectedDay, equalTo: month, toGranularity: .month) {
            self.selectedDay = nil
        }
    }

    private func reconcileRange(_ validMonths: [Date]) {
        // A refresh may remove the month being viewed. Clamp once, without animating
        // through pages that no longer exist. Adding months keeps the current page ID.
        guard let first = validMonths.first, let last = validMonths.last else { return }
        let month = min(max(CalendarDateMath.startOfMonth(visibleMonth), first), last)
        if visibleMonth != month { publishMonth(month) }
        if scrollMonth.map({ !validMonths.contains($0) }) ?? true {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { scrollMonth = month }
        }
    }
}

/// Page content has no dependency on scroll offset or phase. Calendar/count work runs
/// when a page or its data changes, never once per gesture frame.
private struct MonthCalendarPage: View {
    let month: Date
    let selectedDay: Date?
    let cellHeight: CGFloat
    let countForDay: (Date) -> Int
    let onSelect: (Date) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LazyVGrid(columns: MonthCalendarLayout.columns, spacing: MonthCalendarLayout.rowSpacing) {
            ForEach(monthCells) { cell in
                if let date = cell.date {
                    dayButton(cell, date: date)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: cellHeight)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var monthCells: [MonthDayCell] {
        let month = CalendarDateMath.startOfMonth(month)
        guard let days = MonthCalendarLayout.calendar.range(of: .day, in: .month, for: month) else {
            return (0..<(MonthCalendarLayout.rowCount * 7)).map {
                MonthDayCell(id: $0, date: nil, day: 0, count: 0, isToday: false)
            }
        }

        let firstWeekday = MonthCalendarLayout.calendar.component(.weekday, from: month)
        let leadingCount = (firstWeekday - MonthCalendarLayout.calendar.firstWeekday + 7) % 7
        var cells = (0..<leadingCount).map {
            MonthDayCell(id: $0, date: nil, day: 0, count: 0, isToday: false)
        }

        for day in days {
            guard let date = MonthCalendarLayout.calendar.date(byAdding: .day, value: day - 1, to: month)
            else { continue }
            cells.append(MonthDayCell(
                id: cells.count,
                date: date,
                day: day,
                count: countForDay(date),
                isToday: MonthCalendarLayout.calendar.isDateInToday(date)))
        }

        while cells.count < MonthCalendarLayout.rowCount * 7 {
            cells.append(MonthDayCell(id: cells.count, date: nil, day: 0, count: 0, isToday: false))
        }
        return cells
    }

    private func dayButton(_ cell: MonthDayCell, date: Date) -> some View {
        let selected = selectedDay.map { MonthCalendarLayout.calendar.isDate($0, inSameDayAs: date) } ?? false

        return Button {
            onSelect(date)
        } label: {
            VStack(spacing: 2) {
                Text(cell.day, format: .number)
                    .font(.subheadline)
                    .fontWeight(selected ? .bold : .regular)
                    .foregroundStyle(dayNumberColor(for: cell, selected: selected))

                if cell.count > 0 {
                    Text(cell.count, format: .number)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor.onSurface(in: colorScheme))
                        .opacity(selected ? 1 : 0.85)
                } else {
                    Text(" ")
                        .font(.caption2)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: cellHeight)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(!selected && cell.count > 0
                          ? Color.accentColor.opacity(0.12) : Color.clear))
            .modifier(SelectedCalendarDayGlass(active: selected))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(cell.isToday && !selected ? Color.accentColor : .clear,
                                  lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MonthCalendarLayout.accessibilityDateFormatter.string(from: date))
        .accessibilityValue(cell.count == 1 ? Text("1 listing") : Text("\(cell.count) listings"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func dayNumberColor(for cell: MonthDayCell, selected: Bool) -> Color {
        if selected { return .accentColor }
        return cell.count == 0 ? .secondary : .primary
    }

}

private enum MonthCalendarLayout {
    static let calendar = ServerTime.calendar
    static let columnSpacing: CGFloat = 4
    static let rowSpacing: CGFloat = 6
    static let columns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: columnSpacing),
        count: 7)

    static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = ServerTime.timeZone
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter
    }()

    static let weekdaySymbols: [String] = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = ServerTime.timeZone
        formatter.locale = .autoupdatingCurrent
        let symbols = formatter.shortStandaloneWeekdaySymbols
            ?? formatter.shortWeekdaySymbols
            ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let first = (calendar.firstWeekday - 1) % symbols.count
        return Array(symbols[first...] + symbols[..<first])
    }()

    static let accessibilityDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = ServerTime.timeZone
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    static let rowCount = 6
}

private struct MonthDayCell: Identifiable {
    let id: Int
    let date: Date?
    let day: Int
    let count: Int
    let isToday: Bool
}

private struct SelectedCalendarDayGlass: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.liquidGlass(RoundedRectangle(cornerRadius: 14, style: .continuous),
                                interactive: true)
        } else {
            content
        }
    }
}

#Preview("Month paging · compact", traits: .fixedLayout(width: 390, height: 780)) {
    MonthCalendarPreview(empty: false)
}

#Preview("Month paging · wide", traits: .fixedLayout(width: 720, height: 800)) {
    MonthCalendarPreview(empty: false)
}

#Preview("Empty calendar · large text", traits: .fixedLayout(width: 390, height: 850)) {
    MonthCalendarPreview(empty: true)
        .environment(\.dynamicTypeSize, .xxxLarge)
}

private struct MonthCalendarPreview: View {
    let empty: Bool
    @State private var month = CalendarDateMath.startOfMonth(Date())
    @State private var day: Date? = Date()

    private var range: (start: Date, end: Date)? {
        guard !empty else { return nil }
        let today = CalendarDateMath.startOfMonth(Date())
        return (ServerTime.calendar.date(byAdding: .month, value: -2, to: today)!,
                ServerTime.calendar.date(byAdding: .month, value: 4, to: today)!)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Button("Today") {
                    month = CalendarDateMath.startOfMonth(Date())
                    day = Date()
                }
                SwiftUIMonthCalendar(selectedDay: $day, visibleMonth: $month,
                                     availableRange: range) { date in
                    empty ? 0 : ServerTime.calendar.component(.day, from: date) % 5
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 22))
                if let day {
                    Text(MonthCalendarLayout.accessibilityDateFormatter.string(from: day))
                } else {
                    Text("Tap a day to view available listings.")
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }
}
