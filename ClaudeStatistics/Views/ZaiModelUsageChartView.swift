import SwiftUI
import Charts

struct ZaiModelUsageChartView: View {
    @ObservedObject var viewModel: ZaiUsageViewModel

    var body: some View {
        UsageCardContainer {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Text("zai.modelUsage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()

                    HStack(spacing: 6) {
                        ForEach(ZaiUsageRange.allCases) { range in
                            Button {
                                Task { await viewModel.selectRange(range) }
                            } label: {
                                Text(LocalizedStringKey(range.titleKey))
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        viewModel.selectedRange == range
                                            ? Color.blue.opacity(0.16)
                                            : Color.gray.opacity(0.12)
                                    )
                                    .foregroundStyle(viewModel.selectedRange == range ? Color.blue : .secondary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if viewModel.isChartLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }

                if let usage = viewModel.modelUsage {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("zai.totalCalls")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                            Text("\(usage.totalCalls)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("zai.totalTokens")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                            Text(abbreviateTokens(usage.totalTokens))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                    }

                    if displayedPoints.isEmpty && !viewModel.isChartLoading {
                        HStack {
                            Spacer()
                            Text("zai.noChartData")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .frame(height: 80)
                    } else {
                        Chart(displayedPoints) { point in
                            BarMark(
                                x: .value("Time", point.time),
                                y: .value("Tokens", point.tokens)
                            )
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.85), Color.cyan.opacity(0.65)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .cornerRadius(3)
                        }
                        .frame(height: 140)
                        .chartXScale(domain: chartWindow.start ... chartWindow.end)
                        .chartXAxis {
                            AxisMarks(values: xAxisValues) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let date = value.as(Date.self) {
                                        Text(axisLabel(for: date))
                                            .font(.system(size: 8))
                                    }
                                }
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let intVal = value.as(Int.self) {
                                        Text(abbreviateTokens(intVal))
                                            .font(.system(size: 8))
                                    }
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var chartWindow: DateInterval {
        viewModel.selectedRange.requestWindow()
    }

    private var displayedPoints: [ZaiChartPoint] {
        guard let usage = viewModel.modelUsage else {
            return []
        }
        return usage.chartPoints(for: viewModel.selectedRange)
    }

    private var xAxisValues: AxisMarkValues {
        switch viewModel.selectedRange {
        case .day:
            return .stride(by: .hour, count: 3)
        case .week:
            return .stride(by: .day)
        }
    }

    private func axisLabel(for date: Date) -> String {
        let fmt = DateFormatter()
        switch viewModel.selectedRange {
        case .day:
            fmt.dateFormat = "HH:00"
        case .week:
            fmt.dateFormat = "MM/dd"
        }
        return fmt.string(from: date)
    }

    private func abbreviateTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}
