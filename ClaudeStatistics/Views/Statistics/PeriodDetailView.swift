import SwiftUI
import ClaudeStatisticsKit

// MARK: - Period Detail View

struct PeriodDetailView: View {
    let stat: PeriodStats
    let periodType: StatsPeriod
    let store: SessionDataStore
    let onBack: () -> Void
    @Binding var selectedProject: ProjectGroup?

    @State private var trendData: [TrendDataPoint] = []
    @State private var topProjects: [TopProject] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("stats.back")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.blue)

                Spacer()

                if supportsShare {
                    Button(action: openSharePreview) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 11, weight: .semibold))
                            Text("share.action.share")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.blue)
                }

                Text(stat.periodLabel)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 1. Overview
                    SectionCard {
                        HStack(spacing: 12) {
                            CostCell(cost: stat.totalCost)
                            Divider().frame(height: 32)
                            TokenCell(tokens: stat.totalTokens)
                            Divider().frame(height: 32)
                            overviewItem("stats.sessions", value: "\(stat.sessionCount)", icon: "list.bullet")
                            Divider().frame(height: 32)
                            overviewItem("stats.messages", value: "\(stat.messageCount)", icon: "message")
                        }
                    }

                    // 2. Trend chart
                    SectionCard {
                        VStack(spacing: 8) {
                            Label("detail.trend", systemImage: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            TrendChartView(dataPoints: trendData, granularity: periodType.trendGranularity)
                        }
                    }
                    .task {
                        trendData = await store.aggregateTrendData(for: stat, periodType: periodType)
                    }

                    // 3. Tokens + Models — unified breakdown
                    CostModelsCard(period: stat)

                    // 4. Top Projects
                    PeriodTopProjectsCard(top: topProjects) { project in
                        // Map TopProject back to ProjectGroup for analytics view
                        let projectSessions = store.sessions.filter { ($0.cwd ?? $0.projectPath) == project.path }
                        guard !projectSessions.isEmpty else { return }

                        let sorted = projectSessions.sorted { $0.lastModified > $1.lastModified }
                        let resolvedPath = sorted.first.map { store.provider.resolvedProjectPath(for: $0) } ?? project.path

                        let group = ProjectGroup(
                            projectPath: project.path,
                            sessions: sorted,
                            resolvedPath: resolvedPath,
                            totalCost: project.cost,
                            totalTokens: project.tokens,
                            totalMessages: project.messageCount,
                            toolUseCount: 0 // Will be re-calculated in analytics view if needed
                        )

                        withAnimation(Theme.springAnimation) {
                            selectedProject = group
                        }
                    }

                    // 5. Tool usage breakdown
                    if !stat.toolUseCounts.isEmpty {
                        SectionCard {
                            VStack(spacing: 6) {
                                HStack {
                                    Label("stats.toolUsage", systemImage: "wrench.and.screwdriver")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(stat.toolUseCount)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                Divider()
                                let sorted = stat.toolUseCounts.sorted { $0.value > $1.value }
                                let maxCount = sorted.first?.value ?? 1
                                ForEach(Array(sorted.prefix(15)), id: \.key) { item in
                                    ToolBarRow(name: item.key, count: item.value, maxCount: maxCount)
                                }
                            }
                        }
                    }

                }
                .padding(12)
            }
            .task {
                topProjects = await store.aggregatePeriodTopProjects(for: stat, periodType: periodType)
            }
        }
    }

    // MARK: - Helpers

    private func overviewItem(_ title: LocalizedStringKey, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricWithDelta<Content: View>(delta: Double?, isInverse: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .overlay(alignment: .bottomTrailing) {
                if let delta {
                    let isPositive = delta >= 0
                    let isGood = isInverse ? !isPositive : isPositive
                    HStack(spacing: 2) {
                        Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 7, weight: .bold))
                        Text(String(format: "%+.1f%%", delta))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(isGood ? Color.green.opacity(0.85) : Color.red.opacity(0.85))
                }
            }
    }

    private func costRow(_ label: LocalizedStringKey, tokens: Int) -> some View {
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

    private var supportsShare: Bool {
        true
    }

    private func openSharePreview() {
        guard let result = store.buildShareRoleResult(for: stat, periodType: periodType) else { return }
        SharePreviewWindowController.show(result: result, source: .periodDetail)
    }
}
