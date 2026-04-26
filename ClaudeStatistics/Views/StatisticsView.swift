import SwiftUI
import ClaudeStatisticsKit

struct StatisticsView: View {
    @ObservedObject var store: SessionDataStore
    var inlineSessionDetailAdapter: InlineSessionDetailAdapter? = nil
    @State private var selectedPeriodDetail: PeriodStats?
    @State private var selectedProjectForAnalytics: ProjectGroup?

    var body: some View {
        VStack(spacing: 0) {
            if let project = selectedProjectForAnalytics {
                ProjectAnalyticsView(
                    group: project,
                    store: store,
                    onBack: {
                        withAnimation(Theme.springAnimation) {
                            selectedProjectForAnalytics = nil
                        }
                    },
                    inlineSessionDetailAdapter: inlineSessionDetailAdapter
                )
            } else if !store.isFullParseComplete && store.parsedStats.isEmpty {
                loadingView
            } else if store.periodStats.isEmpty {
                emptyView
            } else if let detail = selectedPeriodDetail {
                PeriodDetailView(
                    stat: detail,
                    periodType: store.selectedPeriod,
                    store: store,
                    onBack: { selectedPeriodDetail = nil },
                    selectedProject: $selectedProjectForAnalytics
                )
            } else {
                statsContent
            }
        }
        .textSelection(.enabled)
        .onAppear {
            // Store auto-loads; no manual trigger needed
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            if let progress = store.parseProgress {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "chart.bar")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("stats.noData")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content

    private var statsContent: some View {
        VStack(spacing: 0) {
            // Period picker (first row, replaces the old provider/all-time summary header)
            PeriodPicker(selection: $store.selectedPeriod)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8)

            if store.selectedPeriod == .all {
                // All-time view takes over the entire area — renders its own header + share button
                if let stat = store.visibleStats.first {
                    AllTimeView(stat: stat, store: store, selectedProject: $selectedProjectForAnalytics)
                } else {
                    emptyView
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Bar chart
                        costChart

                        // Period list
                        periodList

                        if store.isFullParseComplete {
                            Text("stats.allParsed")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: - Cost Chart

    private var costChart: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("stats.costByPeriod") + Text(" ") + Text(store.selectedPeriod.localizedName)
                } icon: {
                    Image(systemName: "chart.bar.fill")
                }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                let items = Array(store.visibleStats.reversed())
                let maxCost = items.map(\.totalCost).max() ?? 1.0

                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(items, id: \.id) { stat in
                        BarChartColumn(
                            cost: stat.totalCost,
                            maxCost: maxCost,
                            label: stat.chartLabel
                        )
                        .frame(maxWidth: 60)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedPeriodDetail = stat }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 110)
            }
        }
    }

    // MARK: - Model Breakdown

    private var modelBreakdown: some View {
        SectionCard {
            VStack(spacing: 6) {
                HStack {
                    Label("stats.modelBreakdown", systemImage: "cpu")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("stats.models \(store.visibleModelBreakdown.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Divider()

                let maxCost = store.visibleModelBreakdown.first?.cost ?? 1.0
                ForEach(store.visibleModelBreakdown) { usage in
                    HStack(spacing: 8) {
                        Text(shortModel(usage.model))
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .frame(width: 110, alignment: .leading)

                        ProgressView(value: usage.cost, total: maxCost)
                            .tint(Color.blue.opacity(0.7))

                        Text(formatCost(usage.cost))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .frame(width: 65, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Period List

    private var periodList: some View {
        VStack(spacing: 0) {
            HStack {
                Label {
                    Text("stats.periodDetails") + Text(" ") + Text(store.selectedPeriod.localizedName)
                } icon: {
                    Image(systemName: "calendar")
                }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("stats.periods \(store.periodStats.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 8)

            VStack(spacing: 4) {
                ForEach(Array(store.periodStats.enumerated()), id: \.element.id) { index, stat in
                    PeriodRow(
                        stat: stat,
                        formatCost: formatCost,
                        costColor: costColor,
                        onTap: { selectedPeriodDetail = stat },
                        comparison: store.periodComparison(for: stat)
                    )
                    .modifier(StaggerSlideIn(index: index))
                }
            }
            .id(store.selectedPeriod)
        }
    }

    // MARK: - Helpers

    private func formatCost(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.2f", cost) }
        if cost >= 0.01 { return String(format: "$%.3f", cost) }
        return String(format: "$%.4f", cost)
    }

    private func formatCostShort(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.1f", cost) }
        return String(format: "$%.2f", cost)
    }

    private func costColor(_ cost: Double) -> Color {
        if cost > 5.0 { return .red }
        if cost > 1.0 { return .orange }
        return .green
    }

    private func shortModel(_ id: String) -> String {
        id.replacingOccurrences(of: "claude-", with: "")
    }
}
