import SwiftUI
import ClaudeStatisticsKit

// MARK: - PeriodModelBreakdownCard

struct PeriodModelBreakdownCard: View {
    let modelBreakdown: [String: ModelUsage]
    let formatCost: (Double) -> String
    let shortModel: (String) -> String

    @State private var expandedModels: Set<String> = []

    var body: some View {
        SectionCard {
            VStack(spacing: 6) {
                HStack {
                    Label("stats.modelBreakdown", systemImage: "cpu")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("stats.models \(modelBreakdown.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Divider()

                let sorted = modelBreakdown.values.sorted { $0.cost > $1.cost }
                let maxCost = sorted.first?.cost ?? 1.0
                VStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, usage in
                        let isExpanded = expandedModels.contains(usage.model)
                        let p = ModelPricing.pricing(for: usage.model)

                        VStack(alignment: .leading, spacing: 0) {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if isExpanded { expandedModels.remove(usage.model) }
                                    else { expandedModels.insert(usage.model) }
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 10)
                                    Text(shortModel(usage.model))
                                        .font(.system(size: 10, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("detail.sessions \(usage.sessionCount)")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.tertiary)
                                    Text(formatCost(usage.cost))
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)

                            ProgressView(value: usage.cost, total: maxCost)
                                .tint(Color.blue.opacity(0.7))
                                .padding(.leading, 16)

                            if isExpanded {
                                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                                    periodCostRow("token.input", tokens: usage.inputTokens, rate: p.input)
                                    periodCostRow("token.output", tokens: usage.outputTokens, rate: p.output)
                                    if usage.cacheCreation5mTokens > 0 {
                                        periodCostRow("token.cache5m", tokens: usage.cacheCreation5mTokens, rate: p.cacheWrite5m)
                                    }
                                    if usage.cacheCreation1hTokens > 0 {
                                        periodCostRow("token.cache1h", tokens: usage.cacheCreation1hTokens, rate: p.cacheWrite1h)
                                    }
                                    if usage.cacheCreation5mTokens == 0 && usage.cacheCreation1hTokens == 0 && usage.cacheCreationTotalTokens > 0 {
                                        periodCostRow("token.cacheWriteFull", tokens: usage.cacheCreationTotalTokens, rate: p.cacheWrite1h)
                                    }
                                    if usage.cacheReadTokens > 0 {
                                        periodCostRow("token.cacheReadFull", tokens: usage.cacheReadTokens, rate: p.cacheRead)
                                    }
                                }
                                .padding(.top, 4)
                                .padding(.leading, 16)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }

                        if idx < sorted.count - 1 {
                            Divider().padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func periodCostRow(_ label: LocalizedStringKey, tokens: Int, rate: Double) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(TimeFormatter.tokenCount(tokens))
                .font(.system(size: 11, design: .monospaced))
                .gridColumnAlignment(.trailing)
            Text("x \(String(format: "$%.2f", rate))/M")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.leading)
            Text(String(format: "$%.4f", Double(tokens) / 1_000_000 * rate))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .gridColumnAlignment(.trailing)
        }
    }
}
