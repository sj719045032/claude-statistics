import SwiftUI
import ClaudeStatisticsKit

struct TrendSection: View {
    let initialGranularity: TrendGranularity
    let loadData: (TrendGranularity) async -> [TrendDataPoint]

    @State private var granularity: TrendGranularity = .hour
    @State private var trendData: [TrendDataPoint] = []
    @State private var isLoading = false

    var body: some View {
        SectionCard {
            VStack(spacing: 8) {
                HStack {
                    Label("detail.trend", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $granularity) {
                        ForEach(TrendGranularity.sessionCases, id: \.self) { g in
                            Text(g.rawValue.capitalized).tag(g)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                if isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(height: 100)
                        .frame(maxWidth: .infinity)
                } else {
                    TrendChartView(dataPoints: trendData, granularity: granularity)
                }
            }
        }
        .task {
            granularity = initialGranularity
            await reload()
        }
        .onChange(of: granularity) { _, _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        isLoading = true
        trendData = await loadData(granularity)
        isLoading = false
    }
}
