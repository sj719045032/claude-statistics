import SwiftUI

struct StatisticsView: View {
    @ObservedObject var viewModel: StatisticsViewModel
    @State private var selectedPeriodDetail: PeriodStats?

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading {
                loadingView
            } else if viewModel.periodStats.isEmpty {
                emptyView
            } else if let detail = selectedPeriodDetail {
                PeriodDetailView(
                    stat: detail,
                    periodType: viewModel.selectedPeriod,
                    onBack: { selectedPeriodDetail = nil }
                )
            } else {
                statsContent
            }
        }
        .onAppear {
            if viewModel.periodStats.isEmpty && !viewModel.isLoading {
                viewModel.loadStatistics()
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 8) {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            if let progress = viewModel.progress {
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
            Text("No session data")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Content

    private var statsContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Picker("Period", selection: $viewModel.selectedPeriod) {
                    ForEach(StatsPeriod.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(0.5)
                } else {
                    Button(action: { viewModel.loadStatistics() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh statistics")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // All-time summary
                    allTimeSummary

                    // Bar chart
                    costChart

                    // Period list
                    periodList

                    if let loadedAt = viewModel.lastLoadedAt {
                        Text("Updated: \(TimeFormatter.relativeDate(loadedAt))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - All-time Summary

    private var allTimeSummary: some View {
        SectionCard {
            HStack(spacing: 12) {
                summaryItem("Total Cost", value: formatCost(viewModel.allTimeCost), icon: "dollarsign.circle", estimated: viewModel.periodStats.contains { $0.hasEstimatedCost })
                Divider().frame(height: 28)
                summaryItem("Sessions", value: "\(viewModel.allTimeSessions)", icon: "list.bullet")
                Divider().frame(height: 28)
                summaryItem("Tokens", value: TimeFormatter.tokenCount(viewModel.allTimeTokens), icon: "number")
                Divider().frame(height: 28)
                summaryItem("Messages", value: "\(viewModel.allTimeMessages)", icon: "message")
            }
        }
    }

    private func summaryItem(_ title: String, value: String, icon: String, estimated: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            HStack(spacing: 1) {
                if estimated {
                    Text("~")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Cost Chart

    private var costChart: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Cost by \(viewModel.selectedPeriod.rawValue) Period", systemImage: "chart.bar.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                let items = Array(viewModel.visibleStats.reversed())
                let maxCost = items.map(\.totalCost).max() ?? 1.0

                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(items, id: \.id) { stat in
                        VStack(spacing: 4) {
                            Text(formatCostShort(stat.totalCost))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)

                            RoundedRectangle(cornerRadius: 3)
                                .fill(barColor(stat.totalCost))
                                .frame(height: max(4, CGFloat(stat.totalCost / maxCost) * 80))

                            Text(stat.periodLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedPeriodDetail = stat }
                    }
                }
                .frame(height: 110)
            }
        }
    }

    // MARK: - Model Breakdown

    private var modelBreakdown: some View {
        SectionCard {
            VStack(spacing: 6) {
                HStack {
                    Label("Model Breakdown", systemImage: "cpu")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(viewModel.visibleModelBreakdown.count) models")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Divider()

                let maxCost = viewModel.visibleModelBreakdown.first?.cost ?? 1.0
                ForEach(viewModel.visibleModelBreakdown) { usage in
                    HStack(spacing: 8) {
                        Text(shortModel(usage.model))
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .frame(width: 110, alignment: .leading)

                        ProgressView(value: usage.cost, total: maxCost)
                            .tint(usage.isEstimated ? Color.orange.opacity(0.7) : Color.blue.opacity(0.7))

                        HStack(spacing: 1) {
                            if usage.isEstimated {
                                Text("~")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                            Text(formatCost(usage.cost))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .frame(width: 65, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Period List

    private var periodList: some View {
        SectionCard {
            VStack(spacing: 6) {
                HStack {
                    Label("\(viewModel.selectedPeriod.rawValue) Details", systemImage: "calendar")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(viewModel.periodStats.count) periods")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Divider()

                ForEach(viewModel.periodStats) { stat in
                    Button(action: { selectedPeriodDetail = stat }) {
                        VStack(spacing: 4) {
                            HStack {
                                Text(stat.periodLabel)
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                HStack(spacing: 1) {
                                    if stat.hasEstimatedCost {
                                        Text("~")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(.orange)
                                    }
                                    Text(formatCost(stat.totalCost))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(costColor(stat.totalCost))
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }

                            HStack(spacing: 12) {
                                miniStat("Sessions", value: "\(stat.sessionCount)")
                                miniStat("Messages", value: "\(stat.messageCount)")
                                miniStat("Tokens", value: TimeFormatter.tokenCount(stat.totalTokens))
                                miniStat("Tools", value: "\(stat.toolUseCount)")
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if stat.id != viewModel.periodStats.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func miniStat(_ label: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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

    private func barColor(_ cost: Double) -> Color {
        if cost > 5.0 { return .red.opacity(0.7) }
        if cost > 1.0 { return .orange.opacity(0.7) }
        return .blue.opacity(0.7)
    }

    private func shortModel(_ id: String) -> String {
        id.replacingOccurrences(of: "claude-", with: "")
    }
}

// MARK: - Period Detail View

struct PeriodDetailView: View {
    let stat: PeriodStats
    let periodType: StatsPeriod
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Stats")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.blue)

                Spacer()

                Text(stat.periodLabel)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Overview
                    SectionCard {
                        HStack(spacing: 12) {
                            overviewItem("Sessions", value: "\(stat.sessionCount)", icon: "list.bullet")
                            Divider().frame(height: 28)
                            overviewItem("Messages", value: "\(stat.messageCount)", icon: "message")
                            Divider().frame(height: 28)
                            overviewItem("Tools", value: "\(stat.toolUseCount)", icon: "wrench")
                        }
                    }

                    // Cost breakdown
                    SectionCard {
                        VStack(spacing: 8) {
                            HStack {
                                Label("Cost Breakdown", systemImage: "dollarsign.circle")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                HStack(spacing: 2) {
                                    if stat.hasEstimatedCost {
                                        Text("~")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.orange)
                                    }
                                    Text(formatCost(stat.totalCost))
                                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                                        .foregroundStyle(costColor(stat.totalCost))
                                }
                            }

                            Divider()

                            costRow("Input Tokens", tokens: stat.totalInputTokens)
                            costRow("Output Tokens", tokens: stat.totalOutputTokens)
                            if stat.cacheCreation5mTokens > 0 {
                                costRow("Cache Write 5m", tokens: stat.cacheCreation5mTokens)
                            }
                            if stat.cacheCreation1hTokens > 0 {
                                costRow("Cache Write 1h", tokens: stat.cacheCreation1hTokens)
                            }
                            if stat.cacheCreation5mTokens == 0 && stat.cacheCreation1hTokens == 0 && stat.cacheCreationTotalTokens > 0 {
                                costRow("Cache Write", tokens: stat.cacheCreationTotalTokens)
                            }
                            if stat.cacheReadTokens > 0 {
                                costRow("Cache Read", tokens: stat.cacheReadTokens)
                            }
                        }
                    }

                    // Token bar
                    SectionCard {
                        VStack(spacing: 6) {
                            HStack {
                                Label("Tokens", systemImage: "number")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(TimeFormatter.tokenCount(stat.totalTokens))
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            }

                            Divider()

                            TokenBar(
                                segments: tokenSegments,
                                total: stat.totalTokens
                            )

                            HStack(spacing: 12) {
                                TokenLegend(color: .blue, label: "Input", value: TimeFormatter.tokenCount(stat.totalInputTokens))
                                TokenLegend(color: .green, label: "Output", value: TimeFormatter.tokenCount(stat.totalOutputTokens))
                                if stat.cacheCreationTotalTokens > 0 {
                                    TokenLegend(color: .orange, label: "Cache W", value: TimeFormatter.tokenCount(stat.cacheCreationTotalTokens))
                                }
                                if stat.cacheReadTokens > 0 {
                                    TokenLegend(color: .purple, label: "Cache R", value: TimeFormatter.tokenCount(stat.cacheReadTokens))
                                }
                            }
                            .font(.system(size: 10))
                        }
                    }

                    // Model breakdown for this period
                    if !stat.modelBreakdown.isEmpty {
                        SectionCard {
                            VStack(spacing: 6) {
                                HStack {
                                    Label("Models", systemImage: "cpu")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(stat.modelBreakdown.count) models")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }

                                Divider()

                                let sorted = stat.modelBreakdown.values.sorted { $0.cost > $1.cost }
                                let maxCost = sorted.first?.cost ?? 1.0
                                ForEach(sorted) { usage in
                                    HStack(spacing: 8) {
                                        Text(shortModel(usage.model))
                                            .font(.system(size: 10, design: .monospaced))
                                            .lineLimit(1)
                                            .frame(width: 110, alignment: .leading)

                                        ProgressView(value: usage.cost, total: maxCost)
                                            .tint(usage.isEstimated ? Color.orange.opacity(0.7) : Color.blue.opacity(0.7))

                                        VStack(alignment: .trailing, spacing: 1) {
                                            HStack(spacing: 1) {
                                                if usage.isEstimated {
                                                    Text("~")
                                                        .font(.system(size: 8, weight: .medium))
                                                        .foregroundStyle(.orange)
                                                }
                                                Text(formatCost(usage.cost))
                                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            }
                                            Text("\(usage.sessionCount) sessions")
                                                .font(.system(size: 8))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .frame(width: 75, alignment: .trailing)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    // MARK: - Helpers

    private func overviewItem(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func costRow(_ label: String, tokens: Int) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(TimeFormatter.tokenCount(tokens))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var tokenSegments: [(color: Color, value: Int)] {
        var segments: [(color: Color, value: Int)] = [
            (.blue, stat.totalInputTokens),
            (.green, stat.totalOutputTokens),
        ]
        if stat.cacheCreationTotalTokens > 0 {
            segments.append((.orange, stat.cacheCreationTotalTokens))
        }
        if stat.cacheReadTokens > 0 {
            segments.append((.purple, stat.cacheReadTokens))
        }
        return segments
    }

    private func formatCost(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.2f", cost) }
        if cost >= 0.01 { return String(format: "$%.3f", cost) }
        return String(format: "$%.4f", cost)
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
