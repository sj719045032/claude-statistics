import SwiftUI
import ClaudeStatisticsKit

struct CostModelsCard: View {
    let models: [ModelUsage]
    let totalCost: Double
    let isEstimated: Bool
    @State private var expandedModels: Set<String> = []

    init(stats: SessionStats) {
        self.models = stats.asModelUsages
        self.totalCost = stats.estimatedCost
        self.isEstimated = stats.isCostEstimated
    }

    init(period: PeriodStats) {
        self.models = period.modelBreakdown.values.sorted { $0.totalTokens > $1.totalTokens }
        self.totalCost = period.totalCost
        self.isEstimated = period.hasEstimatedCost
    }

    init(models: [ModelUsage]) {
        self.models = models.sorted { $0.totalTokens > $1.totalTokens }
        self.totalCost = models.reduce(0) { $0 + $1.cost }
        self.isEstimated = models.contains { $0.isEstimated }
    }

    private var totalIn: Int { models.reduce(0) { $0 + $1.inputTokens } }
    private var totalOut: Int { models.reduce(0) { $0 + $1.outputTokens } }
    private var totalC5m: Int { models.reduce(0) { $0 + $1.cacheCreation5mTokens } }
    private var totalC1h: Int { models.reduce(0) { $0 + $1.cacheCreation1hTokens } }
    private var totalCW: Int { models.reduce(0) { $0 + $1.cacheCreationTotalTokens } }
    private var totalCR: Int { models.reduce(0) { $0 + $1.cacheReadTokens } }
    private var grandTotal: Int { totalIn + totalOut + totalCW + totalCR }

    var body: some View {
        SectionCard {
            VStack(spacing: 8) {
                // Section title
                Label("detail.tokensAndModels", systemImage: "number")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Summary: Tokens + Cost
                HStack {
                    Text(TimeFormatter.tokenCount(grandTotal))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.blue)
                    Spacer()
                    if models.count > 1 {
                        Text("detail.models \(models.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Text(detailFormatCost(totalCost))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(detailCostColor(totalCost))
                }

                // Token type bar + legend
                if grandTotal > 0 {
                    TokenBar(
                        segments: {
                            var s: [(color: Color, value: Int)] = [(.blue, totalIn), (.green, totalOut)]
                            if totalCW > 0 { s.append((.orange, totalCW)) }
                            if totalCR > 0 { s.append((.purple, totalCR)) }
                            return s
                        }(),
                        total: grandTotal
                    )
                    tokenLegendRow(input: totalIn, output: totalOut, cache5m: totalC5m, cache1h: totalC1h, cacheTotal: totalCW, cacheRead: totalCR)
                }

                Divider()

                // Model breakdown
                let visibleModels = models.filter { $0.totalTokens > 0 }
                VStack(spacing: 0) {
                    ForEach(Array(visibleModels.enumerated()), id: \.element.id) { idx, item in
                        let isExpanded = expandedModels.contains(item.model)

                        VStack(alignment: .leading, spacing: 0) {
                            // Model summary row (tappable)
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if isExpanded { expandedModels.remove(item.model) }
                                    else { expandedModels.insert(item.model) }
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 10)
                                    Text(detailDisplayModel(item.model))
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    HStack(spacing: 4) {
                                        if item.sessionCount > 1 {
                                            Text("detail.sessions \(item.sessionCount)")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.tertiary)
                                        }
                                        if item.messageCount > 0 {
                                            Text("detail.msgs \(item.messageCount)")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    let pct = grandTotal > 0 ? Double(item.totalTokens) / Double(grandTotal) * 100 : 0
                                    Text("\(TimeFormatter.tokenCount(item.totalTokens)) (\(String(format: "%.2f", pct))%)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(detailFormatCost(item.cost))
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(detailCostColor(item.cost))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)

                            // Expandable cost detail
                            if isExpanded {
                                let p = ModelPricing.pricing(for: item.model)
                                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                                    costDetailRow("token.input", tokens: item.inputTokens, rate: p.input)
                                    costDetailRow("token.output", tokens: item.outputTokens, rate: p.output)
                                    if item.cacheCreation5mTokens > 0 {
                                        costDetailRow("token.cache5m", tokens: item.cacheCreation5mTokens, rate: p.cacheWrite5m)
                                    }
                                    if item.cacheCreation1hTokens > 0 {
                                        costDetailRow("token.cache1h", tokens: item.cacheCreation1hTokens, rate: p.cacheWrite1h)
                                    }
                                    if item.cacheCreation5mTokens == 0 && item.cacheCreation1hTokens == 0 && item.cacheCreationTotalTokens > 0 {
                                        costDetailRow("token.cacheWriteFull", tokens: item.cacheCreationTotalTokens, rate: p.cacheWrite1h)
                                    }
                                    if item.cacheReadTokens > 0 {
                                        costDetailRow("token.cacheReadFull", tokens: item.cacheReadTokens, rate: p.cacheRead)
                                    }
                                }
                                .padding(.top, 4)
                                .padding(.leading, 16)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }

                        if idx < models.count - 1 {
                            Divider().padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func costDetailRow(_ label: LocalizedStringKey, tokens: Int, rate: Double) -> some View {
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

@ViewBuilder
func tokenLegendRow(input: Int, output: Int, cache5m: Int, cache1h: Int, cacheTotal: Int, cacheRead: Int) -> some View {
    let items: [(Color, LocalizedStringKey, Int)] = [
        (.blue, "token.input", input),
        (.green, "token.output", output),
        cache5m > 0 ? (.yellow, "token.cache5m", cache5m) : nil,
        cache1h > 0 ? (.orange, "token.cache1h", cache1h) : nil,
        cache5m == 0 && cache1h == 0 && cacheTotal > 0 ? (.orange, "token.cacheWrite", cacheTotal) : nil,
        cacheRead > 0 ? (.purple, "token.cacheRead", cacheRead) : nil,
    ].compactMap { $0 }

    FlowLayout(spacing: 6) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            TokenLegend(color: item.0, label: item.1, value: TimeFormatter.tokenCount(item.2))
        }
    }
    .font(.system(size: 10))
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { total, row in
            total + row.height + (total > 0 ? 4 : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        var idx = 0
        for row in rows {
            var x = bounds.minX
            for _ in 0..<row.count {
                let size = subviews[idx].sizeThatFits(.unspecified)
                subviews[idx].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
                idx += 1
            }
            y += row.height + 4
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [(count: Int, height: CGFloat)] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [(count: Int, height: CGFloat)] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0
        var currentCount = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if currentCount > 0 && currentWidth + spacing + size.width > maxWidth {
                rows.append((count: currentCount, height: currentHeight))
                currentWidth = size.width
                currentHeight = size.height
                currentCount = 1
            } else {
                currentWidth += (currentCount > 0 ? spacing : 0) + size.width
                currentHeight = max(currentHeight, size.height)
                currentCount += 1
            }
        }
        if currentCount > 0 { rows.append((count: currentCount, height: currentHeight)) }
        return rows
    }
}

struct TokenLegend: View {
    let color: Color
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color.opacity(0.7))
                .frame(width: 6, height: 6)
            (Text(label) + Text(": \(value)"))
                .foregroundStyle(.secondary)
        }
    }
}
