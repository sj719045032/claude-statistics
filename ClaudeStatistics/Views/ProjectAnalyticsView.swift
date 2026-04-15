import SwiftUI

struct ProjectAnalyticsView: View {
    let group: ProjectGroup
    @ObservedObject var store: SessionDataStore
    let onBack: () -> Void

    @State private var modelUsages: [ModelUsage] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("detail.back")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.blue)

                Spacer()

                Text(group.shortPath)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 1. Key Metrics
                    SectionCard {
                        VStack(spacing: 8) {
                            HStack(spacing: 16) {
                                CostCell(cost: group.totalCost)
                                Divider().frame(height: 28)
                                TokenCell(tokens: group.totalTokens)
                            }
                            Divider()
                            HStack(spacing: 16) {
                                InfoCell(title: "detail.sessions", value: "\(group.sessions.count)", icon: "list.bullet")
                                Divider().frame(height: 28)
                                InfoCell(title: "detail.messages", value: "\(group.totalMessages)", icon: "message")
                                Divider().frame(height: 28)
                                InfoCell(title: "stats.tools", value: "\(group.toolUseCount)", icon: "wrench")
                            }
                        }
                    }

                    // 2. Trend chart
                    TrendSection(
                        initialGranularity: .day,
                        loadData: { gran in
                            await store.aggregateProjectTrendData(sessions: group.sessions, granularity: gran)
                        }
                    )

                    // 3. Tokens + Models — unified breakdown
                    if !modelUsages.isEmpty {
                        CostModelsCard(models: modelUsages)
                    }

                    // 4. Tools
                    if group.toolUseCount > 0 {
                        let toolCounts = aggregatedToolCounts()
                        if !toolCounts.isEmpty {
                            SectionCard {
                                VStack(spacing: 6) {
                                    HStack {
                                        Label("detail.tools", systemImage: "wrench.and.screwdriver")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("detail.calls \(group.toolUseCount)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Divider()
                                    let maxCount = toolCounts.first?.count ?? 1
                                    ForEach(Array(toolCounts.prefix(15).enumerated()), id: \.element.name) { index, item in
                                        ToolBarRow(name: item.name, count: item.count, maxCount: maxCount, delay: Double(index) * 0.03)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .task {
            modelUsages = store.aggregateProjectModelBreakdown(sessions: group.sessions)
        }
    }

    // MARK: - Helpers

    private func aggregatedToolCounts() -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for session in group.sessions {
            guard let stats = store.parsedStats[session.id] else { continue }
            for (tool, count) in stats.toolUseCounts {
                counts[tool, default: 0] += count
            }
        }
        return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }
}
