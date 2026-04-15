import SwiftUI
import AppKit

struct SessionDetailView: View {
    let session: Session
    let providerDisplayName: String
    let supportsCost: Bool
    var topic: String? = nil
    var sessionName: String? = nil
    let stats: SessionStats?
    let isLoading: Bool
    let onNewSession: () -> Void
    let onResume: () -> Void
    let loadTrendData: (TrendGranularity) async -> [TrendDataPoint]
    let onBack: () -> Void
    var onDelete: (() -> Void)? = nil
    var onViewTranscript: (() -> Void)? = nil

    @State private var showDeleteConfirm = false
    @State private var isTopicExpanded = false
    @State private var isPromptExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
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

                if onDelete != nil {
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.hoverScale)
                }

                if let onViewTranscript {
                    Button(action: onViewTranscript) {
                        Label("detail.transcript", systemImage: "text.bubble")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button(action: onNewSession) {
                    Label("detail.new", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: onResume) {
                    Label("detail.resume", systemImage: "terminal")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Title
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(session.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            CopyButton(text: session.displayName, help: "detail.copyPath")
                        }
                        HStack(spacing: 4) {
                            Text(session.externalID)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            CopyButton(text: session.externalID, help: "detail.copyId")
                        }
                        if let sessionName, !sessionName.isEmpty {
                            Text(sessionName)
                                .font(.system(size: 12))
                                .foregroundStyle(.blue)
                        }
                        if let topic, !topic.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(isTopicExpanded ? nil : 2)
                                    .animation(.easeInOut(duration: 0.2), value: isTopicExpanded)

                                // Show expand/collapse only when text is long enough
                                if topic.count > 80 {
                                    Button(action: { isTopicExpanded.toggle() }) {
                                        if isTopicExpanded {
                                            Text("detail.collapse")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.blue)
                                        } else {
                                            Text("detail.more")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("detail.parsing")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if let stats {
                        statsContent(stats)
                    }
                }
                .padding(12)
                .textSelection(.enabled)
            }
        }
        .overlay(alignment: .bottom) {
            if showDeleteConfirm {
                VStack(spacing: 8) {
                    Text("detail.deleteConfirm")
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                    Text("session.deleteWarning")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("session.cancel") {
                            showDeleteConfirm = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("session.delete") {
                            showDeleteConfirm = false
                            onDelete?()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(.ultraThickMaterial)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showDeleteConfirm)
    }

    @ViewBuilder
    private func statsContent(_ stats: SessionStats) -> some View {
        // 1. Overview — identity: what session is this
        SectionCard {
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    InfoCell(title: "detail.model", value: displayModel(stats.model), icon: "cpu")
                    Divider().frame(height: 28)
                    if let duration = stats.duration {
                        InfoCell(title: "detail.duration", value: TimeFormatter.duration(duration), icon: "clock")
                        Divider().frame(height: 28)
                    }
                    InfoCell(title: "detail.size", value: TimeFormatter.fileSize(session.fileSize), icon: "doc")
                }
                if let start = stats.startTime {
                    Divider()
                    HStack(spacing: 16) {
                        InfoCell(title: "detail.started", value: TimeFormatter.absoluteDate(start), icon: "calendar")
                        if let end = stats.endTime {
                            Divider().frame(height: 28)
                            InfoCell(title: "detail.lastActive", value: TimeFormatter.absoluteDate(end), icon: "clock.arrow.circlepath")
                        }
                    }
                }
            }
        }

        // 2. Key Metrics
        SectionCard {
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    CostCell(cost: stats.estimatedCost)
                    Divider().frame(height: 28)
                    TokenCell(tokens: stats.totalTokens)
                    if stats.contextTokens > 0 {
                        Divider().frame(height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Label("detail.context", systemImage: "rectangle.stack")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            HStack(spacing: 2) {
                                Text("\(TimeFormatter.tokenCount(stats.contextTokens))/\(TimeFormatter.tokenCount(stats.contextWindowSize))")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                Text(String(format: "%.0f%%", stats.contextUsagePercent))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(contextColor(stats.contextUsagePercent))
                            }
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                HStack(spacing: 16) {
                    InfoCell(title: "detail.messages", value: "\(stats.messageCount)", icon: "message")
                    Divider().frame(height: 28)
                    InfoCell(title: "detail.user", value: "\(stats.userMessageCount)", icon: "person")
                    Divider().frame(height: 28)
                    InfoCell(title: "detail.assistant", value: "\(stats.assistantMessageCount)", icon: "brain")
                }
            }
        }

        // 3. Trend — how usage changed over time
        TrendSection(
            initialGranularity: TrendGranularity.autoSelect(for: stats.duration),
            loadData: loadTrendData
        )

        // 4. Tokens + Models — unified breakdown
        CostModelsCard(stats: stats)

        // 6. Tools
        if !stats.toolUseCounts.isEmpty {
            SectionCard {
                VStack(spacing: 6) {
                    HStack {
                        Label("detail.tools", systemImage: "wrench.and.screwdriver")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("detail.calls \(stats.toolUseTotal)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Divider()

                    let maxCount = stats.sortedToolUses.first?.count ?? 1
                    ForEach(Array(stats.sortedToolUses.enumerated()), id: \.element.name) { index, tool in
                        ToolBarRow(name: tool.name, count: tool.count, maxCount: maxCount, delay: Double(index) * 0.03)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func displayModel(_ model: String) -> String {
        model.replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20", with: " (20")
            .appending(model.contains("-20") ? ")" : "")
    }

    private func formatCost(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.2f", cost) }
        if cost >= 0.01 { return String(format: "$%.3f", cost) }
        return String(format: "$%.4f", cost)
    }

    private func costColor(_ cost: Double) -> Color {
        if cost > 1.0 { return .red }
        if cost > 0.1 { return .orange }
        return .green
    }

    private func contextColor(_ percent: Double) -> Color {
        if percent > 80 { return .red }
        if percent > 50 { return .orange }
        return .green
    }

    private func costGridRow(_ label: LocalizedStringKey, tokens: Int, rate: Double) -> some View {
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

    private func tokenSegments(_ stats: SessionStats) -> [(color: Color, value: Int)] {
        var segments: [(color: Color, value: Int)] = [
            (.blue, stats.totalInputTokens),
            (.green, stats.totalOutputTokens),
        ]
        if stats.cacheCreation5mTokens > 0 {
            segments.append((.yellow, stats.cacheCreation5mTokens))
        }
        if stats.cacheCreation1hTokens > 0 {
            segments.append((.orange, stats.cacheCreation1hTokens))
        }
        if stats.cacheCreation5mTokens == 0 && stats.cacheCreation1hTokens == 0 && stats.cacheCreationTotalTokens > 0 {
            segments.append((.orange, stats.cacheCreationTotalTokens))
        }
        if stats.cacheReadTokens > 0 {
            segments.append((.purple, stats.cacheReadTokens))
        }
        return segments
    }
}

// MARK: - Trend Section (reusable)

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

// MARK: - Components

struct SectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .cardStyle()
    }
}

struct InfoCell: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct CostCell: View {
    let cost: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("detail.cost", systemImage: "dollarsign.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(detailFormatCost(cost))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(detailCostColor(cost))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.quickSpring, value: cost)
    }
}

struct TokenCell: View {
    let tokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("detail.tokens", systemImage: "number")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(TimeFormatter.tokenCount(tokens))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.blue)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Theme.quickSpring, value: tokens)
    }
}

struct TokenBar: View {
    let segments: [(color: Color, value: Int)]
    let total: Int

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    let ratio = total > 0 ? Double(segment.value) / Double(total) : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment.color.opacity(0.7))
                        .frame(width: max(0, geo.size.width * ratio - 1))
                }
            }
        }
        .frame(height: 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
    }
}

// MARK: - Shared helpers (file-level)

private func detailFormatCost(_ cost: Double) -> String {
    if cost >= 1.0 { return String(format: "$%.2f", cost) }
    if cost >= 0.01 { return String(format: "$%.3f", cost) }
    return String(format: "$%.4f", cost)
}

private func detailCostColor(_ cost: Double) -> Color {
    if cost > 1.0 { return .red }
    if cost > 0.1 { return .orange }
    return .green
}

private func detailDisplayModel(_ model: String) -> String {
    model.replacingOccurrences(of: "claude-", with: "")
        .replacingOccurrences(of: "-20", with: " (20")
        .appending(model.contains("-20") ? ")" : "")
}

// MARK: - CostModelsCard

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
                                    if item.messageCount > 0 {
                                        Text("detail.msgs \(item.messageCount)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                    } else if item.sessionCount > 1 {
                                        Text("detail.sessions \(item.sessionCount)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
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

struct ToolBarRow: View {
    let name: String
    let count: Int
    let maxCount: Int
    let delay: Double
    @State private var animatedWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .frame(width: 100, alignment: .leading)

            GeometryReader { geo in
                let target = geo.size.width * CGFloat(count) / CGFloat(max(1, maxCount))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.1))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.5), Color.blue.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: animatedWidth)
                }
                .onAppear {
                    withAnimation(.easeOut(duration: 0.5).delay(delay)) {
                        animatedWidth = target
                    }
                }
            }
            .frame(height: 6)
            .clipped()

            Text("\(count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 35, alignment: .trailing)
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
