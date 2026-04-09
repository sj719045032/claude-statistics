import SwiftUI

struct StatisticsView: View {
    @ObservedObject var store: SessionDataStore
    @State private var selectedPeriodDetail: PeriodStats?

    var body: some View {
        VStack(spacing: 0) {
            if !store.isFullParseComplete && store.parsedStats.isEmpty {
                loadingView
            } else if store.periodStats.isEmpty {
                emptyView
            } else if let detail = selectedPeriodDetail {
                PeriodDetailView(
                    stat: detail,
                    periodType: store.selectedPeriod,
                    store: store,
                    onBack: { selectedPeriodDetail = nil }
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
            // All-time summary (fixed at top)
            allTimeSummary
                .padding(.horizontal, 12)
                .padding(.top, 8)

            // Period picker
            PeriodPicker(selection: $store.selectedPeriod)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

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

    // MARK: - All-time Summary

    private var allTimeSummary: some View {
        SectionCard {
            HStack(spacing: 12) {
                summaryItem("stats.totalCost", value: formatCost(store.allTimeCost), icon: "dollarsign.circle", estimated: store.periodStats.contains { $0.hasEstimatedCost })
                Divider().frame(height: 28)
                summaryItem("stats.sessions", value: "\(store.allTimeSessions)", icon: "list.bullet")
                Divider().frame(height: 28)
                summaryItem("stats.tokens", value: TimeFormatter.tokenCount(store.allTimeTokens), icon: "number")
                Divider().frame(height: 28)
                summaryItem("stats.messages", value: "\(store.allTimeMessages)", icon: "message")
            }
        }
    }

    private func summaryItem(_ title: LocalizedStringKey, value: String, icon: String, estimated: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
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
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.quickSpring, value: value)
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
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, stat in
                        BarChartColumn(
                            cost: stat.totalCost,
                            maxCost: maxCost,
                            label: stat.periodLabel,
                            delay: Double(index) * 0.04
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
                        onTap: { selectedPeriodDetail = stat }
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

// MARK: - Animated Bar Chart Column

private struct BarChartColumn: View {
    let cost: Double
    let maxCost: Double
    let label: String
    let delay: Double

    @State private var animatedHeight: CGFloat = 0
    @State private var isHovered = false

    private var targetHeight: CGFloat {
        max(4, CGFloat(cost / maxCost) * 80)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(formatCostShort(cost))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.barGradient(cost))
                .frame(height: animatedHeight)
                .scaleEffect(x: isHovered ? 1.08 : 1.0, anchor: .bottom)

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .onHover { hovering in
            withAnimation(Theme.quickSpring) { isHovered = hovering }
        }
        .onAppear {
            withAnimation(Theme.springAnimation.delay(delay)) {
                animatedHeight = targetHeight
            }
        }
        .onChange(of: cost) { _, _ in
            withAnimation(Theme.springAnimation) {
                animatedHeight = targetHeight
            }
        }
    }

    private func formatCostShort(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.1f", cost) }
        return String(format: "$%.2f", cost)
    }
}

// MARK: - Period Picker with Sliding Capsule

struct PeriodPicker: View {
    @Binding var selection: StatsPeriod
    @Namespace private var pickerNamespace
    @State private var isHovered: StatsPeriod?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatsPeriod.allCases, id: \.self) { period in
                Button {
                    withAnimation(Theme.tabAnimation) {
                        selection = period
                    }
                } label: {
                    Text(period.localizedName)
                        .font(.system(size: 12, weight: selection == period ? .semibold : .regular))
                        .foregroundStyle(selection == period ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if selection == period {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.15))
                            .matchedGeometryEffect(id: "period_bg", in: pickerNamespace)
                    }
                }
                .onHover { hovering in
                    withAnimation(Theme.quickSpring) {
                        isHovered = hovering ? period : nil
                    }
                }
            }
        }
        .padding(3)
        .background(Color.gray.opacity(0.08))
        .clipShape(Capsule())
    }
}

// MARK: - Stagger Slide In

private struct StaggerSlideIn: ViewModifier {
    let index: Int
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .offset(x: appeared ? 0 : 40)
            .opacity(appeared ? 1 : 0)
            .onAppear {
                withAnimation(Theme.quickSpring.delay(Double(index) * 0.04)) {
                    appeared = true
                }
            }
    }
}

// MARK: - Period Row

private struct PeriodRow: View {
    let stat: PeriodStats
    let formatCost: (Double) -> String
    let costColor: (Double) -> Color
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(stat.periodLabel)
                        .font(.system(size: 11, weight: .semibold))
                    HStack(spacing: 8) {
                        HStack(spacing: 1) {
                            if stat.hasEstimatedCost {
                                Text("~")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                            Text(formatCost(stat.totalCost))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(costColor(stat.totalCost))
                        }
                        Text(TimeFormatter.tokenCount(stat.totalTokens))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.blue)
                    }
                }
                .frame(minWidth: 90, alignment: .leading)

                Spacer()

                HStack(spacing: 12) {
                    miniStat("stats.sessions", value: "\(stat.sessionCount)")
                    miniStat("stats.messages", value: "\(stat.messageCount)")
                    miniStat("stats.tools", value: "\(stat.toolUseCount)")
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            if isHovered {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: Theme.cardShadowColor, radius: 4, y: 1)
        .padding(.bottom, 4)
        .onHover { hovering in
            withAnimation(Theme.quickSpring) { isHovered = hovering }
        }
    }

    private func miniStat(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

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
                                    HStack(spacing: 1) {
                                        if usage.isEstimated {
                                            Text("~")
                                                .font(.system(size: 8, weight: .medium))
                                                .foregroundStyle(.orange)
                                        }
                                        Text(formatCost(usage.cost))
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 3)

                            ProgressView(value: usage.cost, total: maxCost)
                                .tint(usage.isEstimated ? Color.orange.opacity(0.7) : Color.blue.opacity(0.7))
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
// MARK: - Period Detail View

struct PeriodDetailView: View {
    let stat: PeriodStats
    let periodType: StatsPeriod
    let store: SessionDataStore
    let onBack: () -> Void

    @State private var trendData: [TrendDataPoint] = []

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
                        VStack(spacing: 8) {
                            HStack(spacing: 16) {
                                CostCell(cost: stat.totalCost, isEstimated: stat.hasEstimatedCost)
                                Divider().frame(height: 28)
                                TokenCell(tokens: stat.totalTokens)
                            }
                            Divider()
                            HStack(spacing: 16) {
                                overviewItem("stats.sessions", value: "\(stat.sessionCount)", icon: "list.bullet")
                                Divider().frame(height: 28)
                                overviewItem("stats.messages", value: "\(stat.messageCount)", icon: "message")
                                Divider().frame(height: 28)
                                overviewItem("stats.tools", value: "\(stat.toolUseCount)", icon: "wrench")
                            }
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
                        trendData = store.aggregateTrendData(for: stat, periodType: periodType)
                    }

                    // 3. Token bar
                    SectionCard {
                        VStack(spacing: 6) {
                            HStack {
                                Label("detail.tokens", systemImage: "number")
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
                                TokenLegend(color: .blue, label: "token.input", value: TimeFormatter.tokenCount(stat.totalInputTokens))
                                TokenLegend(color: .green, label: "token.output", value: TimeFormatter.tokenCount(stat.totalOutputTokens))
                                if stat.cacheCreationTotalTokens > 0 {
                                    TokenLegend(color: .orange, label: "token.cacheWrite", value: TimeFormatter.tokenCount(stat.cacheCreationTotalTokens))
                                }
                                if stat.cacheReadTokens > 0 {
                                    TokenLegend(color: .purple, label: "token.cacheRead", value: TimeFormatter.tokenCount(stat.cacheReadTokens))
                                }
                            }
                            .font(.system(size: 10))
                        }
                    }

                    // 4. Models detail
                    CostModelsCard(period: stat, showCostHeader: false)

                }
                .padding(12)
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
}
