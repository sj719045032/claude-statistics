import SwiftUI

/// GitHub-style activity heatmap rendered with pure SwiftUI — no Swift Charts.
///
/// Swift Charts' auto-sized `RectangleMark` grid leaves too much horizontal
/// padding for this use case, so the layout is hand-built: one column per ISO
/// week (7 tightly-packed cells), weekday labels on the left, month labels
/// floating above the week that contains a month's 1st.
struct CalendarHeatmap: View {
    let buckets: [Date: DailyHeatmapBucket]
    /// Which metric to colour the cells by.
    let metric: Metric
    /// Time window to render. Defaults to GitHub-style "last 12 months".
    let scope: Scope

    @State private var hoveredCellID: Date?

    init(buckets: [Date: DailyHeatmapBucket], metric: Metric, scope: Scope = .last12Months) {
        self.buckets = buckets
        self.metric = metric
        self.scope = scope
    }

    enum Metric {
        case cost
        case tokens
    }

    enum Scope: Equatable, Hashable {
        /// Rolling 53-week window ending with the current week.
        case last12Months
        /// Jan 1 → Dec 31 of the given calendar year.
        case year(Int)
    }

    // MARK: - Layout tokens

    private let cellSize: CGFloat = 11
    private let cellSpacing: CGFloat = 3
    private let monthLabelHeight: CGFloat = 12
    private let weekdayLabelWidth: CGFloat = 28

    /// Reusable date formatter for tooltip strings — creating a new formatter
    /// inside `tooltip(for:)` for every one of 371 cells was the dominant
    /// bottleneck while scrolling the grid horizontally.
    private static let tooltipDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = LanguageManager.currentLocale
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Data shape

    private struct Column: Identifiable {
        let id: Date
        let weekStart: Date
        let cells: [Cell]
    }

    private struct Cell: Identifiable {
        let id: Date
        let date: Date
        /// 0 = Sunday ... 6 = Saturday
        let weekday: Int
        /// `-1` means a future day (render as clear placeholder).
        let value: Double
    }

    /// Generates the list of weekly columns spanning the active `scope`.
    ///
    /// - `.last12Months` renders a 53-week rolling window ending at the current week.
    /// - `.year(Y)` renders every ISO week that contains any day from Jan 1 – Dec 31
    ///   of year Y. The grid always starts on a week boundary so every column has
    ///   a full 7-cell stack.
    private var columns: [Column] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let (gridStart, gridEnd) = gridRange(today: today, cal: cal)

        var cols: [Column] = []
        var weekStart = gridStart
        while weekStart < gridEnd {
            var cells: [Cell] = []
            for i in 0..<7 {
                let day = cal.date(byAdding: .day, value: i, to: weekStart) ?? weekStart
                let raw: Double
                if day > today {
                    raw = -1
                } else {
                    let b = buckets[cal.startOfDay(for: day)]
                    raw = metric == .cost ? (b?.cost ?? 0) : Double(b?.tokens ?? 0)
                }
                cells.append(Cell(id: day, date: day, weekday: i, value: raw))
            }
            cols.append(Column(id: weekStart, weekStart: weekStart, cells: cells))
            weekStart = cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
        }
        return cols
    }

    /// Computes the `[start, end)` week-boundary range to render for the current scope.
    private func gridRange(today: Date, cal: Calendar) -> (start: Date, end: Date) {
        switch scope {
        case .last12Months:
            let todayWeek = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
            let currentWeekStart = cal.date(from: todayWeek) ?? today
            let start = cal.date(byAdding: .weekOfYear, value: -52, to: currentWeekStart) ?? currentWeekStart
            // End = start of *next* week so the while-loop includes the current week.
            let end = cal.date(byAdding: .day, value: 7, to: currentWeekStart) ?? today
            return (start, end)

        case .year(let year):
            let jan1 = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today
            let jan1Week = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: jan1)
            let start = cal.date(from: jan1Week) ?? jan1

            let dec31 = cal.date(from: DateComponents(year: year, month: 12, day: 31)) ?? today
            let dec31Week = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: dec31)
            let dec31WeekStart = cal.date(from: dec31Week) ?? dec31
            let end = cal.date(byAdding: .day, value: 7, to: dec31WeekStart) ?? dec31
            return (start, end)
        }
    }

    /// 4 thresholds cut the non-zero active range into 5 visual buckets.
    /// Uses the 85th percentile as the "high" end so a few extreme days don't
    /// crush everything else into a single pale bucket.
    private var thresholds: [Double] {
        let active = buckets.values
            .map { metric == .cost ? $0.cost : Double($0.tokens) }
            .filter { $0 > 0 }
            .sorted()
        guard let top = active.last, top > 0 else { return [0, 0, 0, 0] }
        let p85 = active[Int(Double(active.count) * 0.85)]
        let ceiling = max(p85, top * 0.3)
        return [
            ceiling * 0.1,
            ceiling * 0.3,
            ceiling * 0.6,
            ceiling * 0.9
        ]
    }

    /// A single day cell. No per-cell `.help` — macOS's system tooltip has a ~1 s
    /// hover delay which felt sluggish. Instead, the hovered cell's detail is
    /// surfaced in `hoverInfoBar` below the grid, updating instantly.
    @ViewBuilder
    private func cellView(for cell: Cell) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color(for: cell.value))
            .frame(width: cellSize, height: cellSize)
            .onHover { hovering in
                if hovering {
                    hoveredCellID = cell.id
                } else if hoveredCellID == cell.id {
                    hoveredCellID = nil
                }
            }
    }

    /// Default scroll anchor for the current scope.
    /// - Rolling `.last12Months`: land on the current week (right edge).
    /// - Specific year: start at Jan (left edge) so the whole year is explorable
    ///   from the beginning.
    private func scrollToScopeDefault(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            switch scope {
            case .last12Months:
                if let last = columns.last {
                    proxy.scrollTo(last.id, anchor: .trailing)
                }
            case .year:
                if let first = columns.first {
                    proxy.scrollTo(first.id, anchor: .leading)
                }
            }
        }
    }

    private func color(for value: Double) -> Color {
        // Future days and no-activity days share the same quiet background —
        // keeps the grid visually complete even at the tail end of the current week.
        if value <= 0 { return Color.primary.opacity(0.06) }
        if value < thresholds[0] { return Color.blue.opacity(0.25) }
        if value < thresholds[1] { return Color.blue.opacity(0.50) }
        if value < thresholds[2] { return Color.blue.opacity(0.75) }
        if value < thresholds[3] { return Color.purple.opacity(0.75) }
        return Color.purple.opacity(0.95)
    }

    // MARK: - View

    var body: some View {
        if columns.isEmpty {
            emptyState
        } else {
            heatmapGrid
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text("allTime.heatmap.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(height: 120)
    }

    private var heatmapGrid: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                weekdayLabels
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            monthLabelRow
                            HStack(alignment: .top, spacing: cellSpacing) {
                                ForEach(columns) { col in
                                    VStack(spacing: cellSpacing) {
                                        ForEach(col.cells) { cell in
                                            cellView(for: cell)
                                        }
                                    }
                                    .id(col.id)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.trailing, 4)
                    }
                    .onAppear { scrollToScopeDefault(scrollProxy) }
                    .onChange(of: scope) { _, _ in scrollToScopeDefault(scrollProxy) }
                }
            }
            hoverInfoBar
                // Indent to line up with the left edge of the cell grid, skipping
                // the weekday-label gutter so the info text visually hangs below
                // the grid itself rather than the container card.
                .padding(.leading, weekdayLabelWidth + 6)
        }
        .padding(.vertical, 4)
    }

    /// Inline info line shown below the grid. Left side: live hover-detail
    /// for the cell under the pointer. Right side: GitHub-style "Less → More"
    /// colour-scale legend so users can decode the density at a glance.
    private var hoverInfoBar: some View {
        HStack(spacing: 8) {
            Text(hoverInfoText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            legend
        }
        .frame(height: 14)
        .padding(.horizontal, 2)
    }

    /// Five swatches that mirror the five non-empty activity buckets the
    /// `color(for:)` function produces.
    private var legend: some View {
        HStack(spacing: 4) {
            Text("allTime.heatmap.less")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            HStack(spacing: 2) {
                ForEach(legendSwatches, id: \.self) { c in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(c)
                        .frame(width: 9, height: 9)
                }
            }
            Text("allTime.heatmap.more")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var legendSwatches: [Color] {
        [
            Color.primary.opacity(0.06),
            Color.blue.opacity(0.25),
            Color.blue.opacity(0.50),
            Color.blue.opacity(0.75),
            Color.purple.opacity(0.95)
        ]
    }

    private var hoverInfoText: String {
        guard let date = hoveredCellID else { return " " }
        let dateStr = Self.tooltipDateFormatter.string(from: date)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        if date > today { return dateStr }
        let bucket = buckets[cal.startOfDay(for: date)]
        let v: Double = {
            switch metric {
            case .cost: return bucket?.cost ?? 0
            case .tokens: return Double(bucket?.tokens ?? 0)
            }
        }()
        if v == 0 { return "\(dateStr) · —" }
        switch metric {
        case .cost:
            return String(format: "%@ · $%.2f", dateStr, v)
        case .tokens:
            return "\(dateStr) · \(TimeFormatter.tokenCount(Int(v)))"
        }
    }

    private var weekdayLabels: some View {
        // Show only Mon / Wed / Fri to keep the column narrow. Spacer rows keep the
        // vertical rhythm aligned with the cells.
        VStack(alignment: .trailing, spacing: cellSpacing) {
            // Spacer for the month-label row above the grid.
            Color.clear.frame(height: monthLabelHeight)
            ForEach(0..<7) { i in
                Text(i == 1 || i == 3 || i == 5 ? weekdayLabel(i) : " ")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(height: cellSize, alignment: .trailing)
            }
        }
        .frame(width: weekdayLabelWidth, alignment: .trailing)
    }

    private var monthLabelRow: some View {
        // Each column is a rigid `cellSize`×`monthLabelHeight` Color.clear — its
        // layout contribution is fixed and does NOT grow with the label text.
        //
        // Label Text is rendered via `.overlay(alignment: .topLeading)` so it
        // hangs with its *left edge* aligned to the left edge of the column
        // that contains day-1. This matches GitHub's heatmap: the label's
        // anchor point is the start of the column, and it extends rightward
        // into neighbouring columns' airspace (empty because adjacent months
        // are always ≥ 4 columns apart).
        //
        // Using `.overlay` rather than a ZStack is important — `.fixedSize()`
        // inside a ZStack would inflate the ZStack itself, pushing every later
        // column to the right and breaking grid-to-cell alignment.
        HStack(spacing: cellSpacing) {
            ForEach(columns) { col in
                Color.clear
                    .frame(width: cellSize, height: monthLabelHeight)
                    .overlay(alignment: .topLeading) {
                        if let label = monthLabelIfFirstWeekOfMonth(col.weekStart) {
                            Text(label)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
            }
        }
        .frame(height: monthLabelHeight, alignment: .leading)
    }

    /// Return the month's short name if this column contains the 1st of a month —
    /// matches GitHub's visual rule: the label sits above the column that actually
    /// has day-1 in it, not the following full week. The label is then leading-
    /// aligned so its left edge lines up with that column.
    private func monthLabelIfFirstWeekOfMonth(_ weekStart: Date) -> String? {
        let cal = Calendar.current
        for i in 0..<7 {
            let day = cal.date(byAdding: .day, value: i, to: weekStart) ?? weekStart
            if cal.component(.day, from: day) == 1 {
                return monthString(day)
            }
        }
        return nil
    }

    private func monthString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = LanguageManager.currentLocale
        fmt.dateFormat = "MMM"
        return fmt.string(from: date)
    }

    private func weekdayLabel(_ weekday: Int) -> String {
        let fmt = DateFormatter()
        fmt.locale = LanguageManager.currentLocale
        let symbols = fmt.shortWeekdaySymbols ?? ["S", "M", "T", "W", "T", "F", "S"]
        return weekday < symbols.count ? symbols[weekday] : ""
    }

    private func tooltip(for cell: Cell) -> String {
        let dateStr = Self.tooltipDateFormatter.string(from: cell.date)
        if cell.value < 0 { return dateStr }
        if cell.value == 0 { return "\(dateStr) · —" }
        switch metric {
        case .cost:
            return String(format: "%@ · $%.2f", dateStr, cell.value)
        case .tokens:
            return "\(dateStr) · \(TimeFormatter.tokenCount(Int(cell.value)))"
        }
    }
}
