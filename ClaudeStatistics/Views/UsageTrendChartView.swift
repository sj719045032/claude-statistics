import SwiftUI
import Charts

/// Cumulative dual-axis chart for subscription usage windows (5h / 7d).
struct UsageTrendChartView: View {
    let dataPoints: [TrendDataPoint]
    let granularity: TrendGranularity
    let windowStart: Date
    let windowEnd: Date

    @State private var hoverDate: Date?
    @State private var hoverValues: (tokens: Int, cost: Double)?
    @State private var hoverLocation: CGPoint = .zero
    @State private var animationProgress: CGFloat = 0

    private var maxTokens: Int {
        dataPoints.map(\.tokens).max() ?? 0
    }
    private var maxCost: Double {
        dataPoints.map(\.cost).max() ?? 0
    }
    private var scaleFactor: Double {
        guard maxCost > 0, maxTokens > 0 else { return 1.0 }
        return Double(maxTokens) / maxCost
    }
    /// Small domain padding so centered edge labels aren't clipped
    private var domainPadding: TimeInterval {
        windowEnd.timeIntervalSince(windowStart) * 0.05
    }
    private var xDomainStart: Date { windowStart.addingTimeInterval(-domainPadding) }
    private var xDomainEnd: Date { windowEnd.addingTimeInterval(domainPadding) }

    var body: some View {
        if dataPoints.isEmpty || (maxTokens == 0 && maxCost == 0) {
            emptyState
        } else {
            chartContent
                .frame(height: 180)
                .mask(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle()
                            .frame(width: geo.size.width * animationProgress)
                            .padding(.vertical, -20)
                    }
                }
                .onAppear {
                    animationProgress = 0
                    withAnimation(.easeOut(duration: 0.8)) {
                        animationProgress = 1
                    }
                }
                .onChange(of: dataPoints.count) { _, _ in
                    animationProgress = 0
                    withAnimation(.easeOut(duration: 0.8)) {
                        animationProgress = 1
                    }
                }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text("No trend data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(height: 80)
    }

    @ViewBuilder
    private var chartContent: some View {
        let useSingleAxis = maxTokens == 0 || maxCost == 0

        Chart {
            if let date = hoverDate {
                RuleMark(x: .value("Selected", date))
                    .foregroundStyle(Color.primary.opacity(0.2))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            ForEach(dataPoints) { point in
                if maxTokens > 0 {
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Tokens", point.tokens),
                        series: .value("Series", "Tokens")
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }

                if maxCost > 0 {
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Tokens", useSingleAxis ? Int(point.cost * 1000) : Int(point.cost * scaleFactor)),
                        series: .value("Series", "Cost")
                    )
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: xDomainStart...xDomainEnd)
        .chartXAxis {
            AxisMarks(values: xAxisValues) { value in
                AxisGridLine()
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(formatXAxisLabel(date))
                            .font(.system(size: 9))
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let intVal = value.as(Int.self) {
                        Text(abbreviateNumber(intVal))
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }
                }
            }
            if !useSingleAxis {
                AxisMarks(position: .trailing) { value in
                    AxisValueLabel {
                        if let intVal = value.as(Int.self) {
                            let realCost = Double(intVal) / scaleFactor
                            Text(abbreviateCost(realCost))
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .chartLegend(position: .top) {
            HStack(spacing: 12) {
                if maxTokens > 0 {
                    legendItem(color: .blue, label: "Tokens")
                }
                if maxCost > 0 {
                    legendItem(color: .orange, label: "Cost")
                }
            }
            .font(.system(size: 10))
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plotFrame = proxy.plotFrame.map { geo[$0] } ?? .zero
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plotX = location.x - plotFrame.origin.x
                            guard plotX >= 0, plotX <= plotFrame.width,
                                  location.y >= plotFrame.origin.y,
                                  location.y <= plotFrame.origin.y + plotFrame.height,
                                  let date: Date = proxy.value(atX: plotX) else {
                                hoverDate = nil
                                hoverValues = nil
                                return
                            }
                            hoverDate = date
                            hoverLocation = CGPoint(x: location.x, y: location.y)
                            hoverValues = ChartInterpolation.interpolate(at: date, in: dataPoints)
                        case .ended:
                            hoverDate = nil
                            hoverValues = nil
                        }
                    }
                    .overlay {
                        if let date = hoverDate, let values = hoverValues {
                            chartTooltip(date: date, tokens: values.tokens, cost: values.cost)
                                .fixedSize()
                                .position(
                                    x: min(max(hoverLocation.x, 50), geo.size.width - 50),
                                    y: max(hoverLocation.y - 40, 10)
                                )
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .animation(Theme.quickSpring, value: hoverDate)
    }

    @ViewBuilder
    private func chartTooltip(date: Date, tokens: Int, cost: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formatTooltipDate(date))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            if maxTokens > 0 {
                HStack(spacing: 3) {
                    Circle().fill(.blue).frame(width: 5, height: 5)
                    Text(abbreviateNumber(tokens))
                        .font(.system(size: 9, design: .monospaced))
                }
            }
            if maxCost > 0 {
                HStack(spacing: 3) {
                    Circle().fill(.orange).frame(width: 5, height: 5)
                    Text(abbreviateCost(cost))
                        .font(.system(size: 9, design: .monospaced))
                }
            }
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        .padding(4)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private var xAxisValues: [Date] {
        let cal = Calendar.current
        let comp = granularity.axisMarkComponent
        
        let windowDuration = windowEnd.timeIntervalSince(windowStart)
        let hoursDuration = windowDuration / 3600.0
        
        // Adjust step dynamically to avoid overlapping labels on long windows with fine granularity
        let step: Int
        if granularity == .fiveMinute && hoursDuration > 12 {
            step = 4 // e.g., for a 24h window, mark every 4 hours instead of every 1 hour
        } else {
            step = granularity.axisMarkCount
        }

        let refDate = cal.date(byAdding: comp, value: step, to: windowStart) ?? windowStart
        let strideInterval = refDate.timeIntervalSince(windowStart)
        let minDistance = strideInterval * 0.5

        var values: [Date] = [windowStart]

        let axisBucket = TrendGranularity(rawValue: granularity.rawValue == "fiveMinute" ? "hour" : (granularity.rawValue == "hour" ? "day" : granularity.rawValue))!
        var markTime = axisBucket.bucketStart(for: windowStart)
        if let next = cal.date(byAdding: comp, value: step, to: markTime) {
            markTime = next
        }

        while markTime < windowEnd {
            let fromStart = markTime.timeIntervalSince(windowStart)
            let fromEnd = windowEnd.timeIntervalSince(markTime)
            if fromStart > minDistance && fromEnd > minDistance {
                values.append(markTime)
            }
            guard let next = cal.date(byAdding: comp, value: step, to: markTime) else { break }
            markTime = next
        }

        values.append(windowEnd)
        return values
    }

    private func formatTooltipDate(_ date: Date) -> String {
        if granularity == .fiveMinute {
            return DateFormatter.with("HH:mm").string(from: date)
        }
        return DateFormatter.with("MM/dd HH:mm").string(from: date)
    }

    private func formatXAxisLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let isStart = abs(date.timeIntervalSince(windowStart)) < 1
        let isEnd = abs(date.timeIntervalSince(windowEnd)) < 1

        if isStart || isEnd {
            let comps = cal.dateComponents([.hour, .minute], from: date)
            let isMidnight = comps.hour == 0 && (comps.minute ?? 0) == 0
            if granularity == .fiveMinute {
                return isMidnight ? "24:00" : DateFormatter.with("HH:mm").string(from: date)
            } else {
                // Two-line label for 7d: "MM/dd\nHH:mm"
                let dayDate = isMidnight ? cal.date(byAdding: .day, value: -1, to: date)! : date
                let dayStr = DateFormatter.with("MM/dd").string(from: dayDate)
                let timeStr = isMidnight ? "24:00" : DateFormatter.with("HH:mm").string(from: date)
                return "\(dayStr)\n\(timeStr)"
            }
        }

        let fmt = DateFormatter()
        fmt.dateFormat = granularity.axisLabelFormat
        return fmt.string(from: date)
    }

    private func abbreviateNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func abbreviateCost(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.1f", cost) }
        if cost >= 0.01 { return String(format: "$%.2f", cost) }
        return String(format: "$%.3f", cost)
    }
}

extension TrendGranularity {
    /// Calendar component for axis marks (may differ from data granularity)
    var axisMarkComponent: Calendar.Component {
        switch self {
        case .fiveMinute: return .hour   // hourly marks for 5h window
        case .hour: return .day          // daily marks for 7d hourly view
        default: return calendarComponent
        }
    }

    /// Axis mark stride count
    var axisMarkCount: Int {
        switch self {
        case .day: return 2
        case .hour: return 1    // daily marks for 7d hourly view
        default: return 1
        }
    }

    /// Axis label date format (may differ from data dateFormatString)
    var axisLabelFormat: String {
        switch self {
        case .fiveMinute: return "HH:00"
        case .hour: return "MM/dd"       // daily labels for 7d hourly view
        default: return dateFormatString
        }
    }
}

private extension DateFormatter {
    static func with(_ format: String) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.dateFormat = format
        return fmt
    }
}
