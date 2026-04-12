import SwiftUI
import Charts

struct TrendChartView: View {
    let dataPoints: [TrendDataPoint]
    let granularity: TrendGranularity

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
    /// Scale factor to normalize cost into the token value range
    private var scaleFactor: Double {
        guard maxCost > 0, maxTokens > 0 else { return 1.0 }
        return Double(maxTokens) / maxCost
    }

    var body: some View {
        if dataPoints.isEmpty {
            emptyState
        } else {
            chartContent
                .frame(height: 200)
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
        .frame(height: 100)
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
                if dataPoints.count == 1 {
                    if maxTokens > 0 {
                        PointMark(
                            x: .value("Time", point.time),
                            y: .value("Tokens", point.tokens)
                        )
                        .foregroundStyle(.blue)
                        .symbolSize(30)
                    }
                    if maxCost > 0 {
                        PointMark(
                            x: .value("Time", point.time),
                            y: .value("Tokens", useSingleAxis ? Int(point.cost * 1000) : Int(point.cost * scaleFactor))
                        )
                        .foregroundStyle(.orange)
                        .symbolSize(30)
                    }
                } else {
                    if maxTokens > 0 {
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("Tokens", point.tokens),
                            series: .value("Series", "Tokens")
                        )
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }
                    if maxCost > 0 {
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("Tokens", useSingleAxis ? Int(point.cost * 1000) : Int(point.cost * scaleFactor)),
                            series: .value("Series", "Cost")
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(formatAxisDate(date))
                            .font(.system(size: 9))
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
                if maxTokens > 0 { legendItem(color: .blue, label: "Tokens") }
                if maxCost > 0 { legendItem(color: .orange, label: "Cost") }
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
            Text(StatsPeriod.smartDate(date))
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

    private func formatAxisDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = granularity.dateFormatString
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
