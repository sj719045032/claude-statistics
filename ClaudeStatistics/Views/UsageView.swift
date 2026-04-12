import SwiftUI

struct UsageView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var store: SessionDataStore
    @State private var selectedWindowTab = "5h"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("usage.title")
                    .font(.headline)
                Spacer()
                Button(action: {
                    if let url = URL(string: "https://claude.ai/settings/usage") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Image(systemName: "safari")
                        .font(.system(size: 11))
                }
                .buttonStyle(.hoverScale)
                .foregroundStyle(.secondary)
                .help("usage.viewOnline")

                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                } else {
                    Button(action: { Task { await viewModel.forceRefresh() } }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.hoverScale)
                    .help("usage.refresh")
                }
            }

            if let usage = viewModel.usageData {
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                UsageWindowRow(
                    title: "usage.5hour",
                    utilization: usage.fiveHour?.utilization ?? 0,
                    countdown: viewModel.fiveHourResetCountdown,
                    exhaustEstimate: viewModel.fiveHourExhaustEstimate
                )

                UsageWindowRow(
                    title: "usage.7day",
                    utilization: usage.sevenDay?.utilization ?? 0,
                    countdown: viewModel.sevenDayResetCountdown,
                    exhaustEstimate: viewModel.sevenDayExhaustEstimate
                )

                if let opus = usage.sevenDayOpus {
                    UsageWindowRow(
                        title: "usage.7dayOpus",
                        utilization: opus.utilization,
                        countdown: opus.timeUntilReset.map { TimeFormatter.countdown(from: $0) },
                        exhaustEstimate: viewModel.sevenDayOpusExhaustEstimate
                    )
                }

                if let sonnet = usage.sevenDaySonnet {
                    UsageWindowRow(
                        title: "usage.7daySonnet",
                        utilization: sonnet.utilization,
                        countdown: sonnet.timeUntilReset.map { TimeFormatter.countdown(from: $0) },
                        exhaustEstimate: viewModel.sevenDaySonnetExhaustEstimate
                    )
                }

                if let extra = usage.extraUsage, extra.isEnabled == true {
                    Divider()
                    HStack {
                        Text("usage.extraUsage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let used = extra.usedCredits {
                            if let limit = extra.monthlyLimit {
                                Text("$\(String(format: "%.2f", used)) / $\(String(format: "%.0f", limit))")
                                    .font(.caption)
                            } else {
                                Text("$\(String(format: "%.2f", used))")
                                    .font(.caption)
                            }
                        }
                    }
                }

                Divider()

                Picker("", selection: $selectedWindowTab) {
                    Text("5h").tag("5h")
                    Text("7d").tag("7d")
                    if usage.sevenDaySonnet != nil {
                        Text("7d Sonnet").tag("7d_sonnet")
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch selectedWindowTab {
                case "5h":
                    windowChart(for: usage.fiveHour, durationValue: -5, durationComponent: .hour, granularity: .fiveMinute, modelFilter: isClaude)
                case "7d":
                    windowChart(for: usage.sevenDay, durationValue: -7, durationComponent: .day, granularity: .hour, modelFilter: isClaude)
                case "7d_sonnet":
                    windowChart(for: usage.sevenDaySonnet, durationValue: -7, durationComponent: .day, granularity: .hour, modelFilter: isSonnet)
                default:
                    EmptyView()
                }
            } else if !viewModel.isLoading {
                // No data — show error or empty state with retry action
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.icloud")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)

                    Text("usage.noData")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(action: { Task { await viewModel.forceRefresh() } }) {
                        Label("usage.retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            if let fetchedAt = viewModel.lastFetchedAt {
                Text("usage.updated \(TimeFormatter.absoluteDate(fetchedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .textSelection(.enabled)
    }
}

extension UsageView {
    struct WindowTrendInfo {
        let dataPoints: [TrendDataPoint]
        let granularity: TrendGranularity
        let windowStart: Date
        let windowEnd: Date
        let modelBreakdown: [ModelUsage]
    }

    private func windowTrendInfo(
        for window: UsageWindow?,
        durationValue: Int,
        durationComponent: Calendar.Component,
        granularity: TrendGranularity,
        modelFilter: ((String) -> Bool)? = nil
    ) -> WindowTrendInfo? {
        guard store.isFullParseComplete,
              let window,
              let resetAt = window.resetsAtDate,
              let start = Calendar.current.date(byAdding: durationComponent, value: durationValue, to: resetAt) else {
            return nil
        }

        let snapshotTime = min(viewModel.lastFetchedAt ?? Date(), resetAt)
        guard start < snapshotTime else { return nil }

        let data = store.aggregateWindowTrendData(from: start, to: snapshotTime, granularity: granularity, cumulative: true, modelFilter: modelFilter)
        let models = store.windowModelBreakdown(from: start, to: snapshotTime, modelFilter: modelFilter)
        return data.isEmpty ? nil : WindowTrendInfo(
            dataPoints: data,
            granularity: granularity,
            windowStart: start,
            windowEnd: resetAt,
            modelBreakdown: models
        )
    }

    // MARK: - Model Filters

    private func isClaude(_ model: String) -> Bool {
        model.lowercased().contains("claude")
    }

    private func isSonnet(_ model: String) -> Bool {
        model.lowercased().contains("sonnet")
    }

    private func isClaudeNonSonnet(_ model: String) -> Bool {
        let lower = model.lowercased()
        return lower.contains("claude") && !lower.contains("sonnet")
    }

    @ViewBuilder
    private func windowChart(
        for window: UsageWindow?,
        durationValue: Int,
        durationComponent: Calendar.Component,
        granularity: TrendGranularity,
        modelFilter: ((String) -> Bool)?
    ) -> some View {
        if let info = windowTrendInfo(for: window, durationValue: durationValue, durationComponent: durationComponent, granularity: granularity, modelFilter: modelFilter) {
            windowTimeRange(info)
            UsageTrendChartView(dataPoints: info.dataPoints, granularity: info.granularity, windowStart: info.windowStart, windowEnd: info.windowEnd)
            if !info.modelBreakdown.isEmpty {
                WindowModelBreakdownView(models: info.modelBreakdown)
            }
        }
    }


    private func windowTimeRange(_ info: WindowTrendInfo) -> some View {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd HH:mm"
        let startStr = formatWindowTime(info.windowStart, fmt: fmt)
        let endStr = formatWindowTime(info.windowEnd, fmt: fmt)
        return Text("\(startStr) — \(endStr)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func formatWindowTime(_ date: Date, fmt: DateFormatter) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        if comps.hour == 0 && (comps.minute ?? 0) == 0 {
            let prevDay = cal.date(byAdding: .day, value: -1, to: date)!
            fmt.dateFormat = "MM/dd"
            let dayStr = fmt.string(from: prevDay)
            fmt.dateFormat = "MM/dd HH:mm"
            return dayStr + " 24:00"
        }
        return fmt.string(from: date)
    }

    func errorBanner(_ error: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            Button(action: { Task { await viewModel.forceRefresh() } }) {
                Text("usage.retry")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }
}

// MARK: - Model Breakdown View

struct WindowModelBreakdownView: View {
    let models: [ModelUsage]
    @State private var showDetail = false

    private var totalTokens: Int { models.reduce(0) { $0 + $1.totalTokens } }
    private var totalCost: Double { models.reduce(0.0) { $0 + $1.cost } }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Summary line
            HStack {
                HStack(spacing: 3) {
                    Text("Tokens").foregroundStyle(.tertiary)
                    Text(abbreviateNumber(totalTokens)).foregroundStyle(.blue)
                }
                Spacer()
                HStack(spacing: 3) {
                    Text("Cost").foregroundStyle(.tertiary)
                    Text(abbreviateCost(totalCost)).foregroundStyle(.orange)
                }
            }
            .font(.caption)

            // Stacked bar
            if totalTokens > 0 {
                Canvas { ctx, size in
                    var x: CGFloat = 0
                    for model in models {
                        let w = size.width * CGFloat(model.totalTokens) / CGFloat(totalTokens)
                        ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)),
                                 with: .color(modelColor(model.model)))
                        x += w
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())
            }

            // Inline legend + detail toggle
            HStack(spacing: 0) {
                HStack(spacing: 10) {
                    ForEach(models) { model in
                        let pct = totalTokens > 0 ? Double(model.totalTokens) / Double(totalTokens) * 100 : 0
                        HStack(spacing: 3) {
                            Circle().fill(modelColor(model.model)).frame(width: 6, height: 6)
                            Text(shortModelName(model.model)).font(.caption2)
                            Text("\(abbreviateNumber(model.totalTokens)) (\(String(format: "%.0f", pct))%)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showDetail.toggle() }
                } label: {
                    HStack(spacing: 2) {
                        Text("detail").font(.caption2)
                        Image(systemName: showDetail ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .medium))
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }

            if showDetail {
                tokenDetailTable
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var tokenDetailTable: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 0) {
                Text("Model").frame(width: 55, alignment: .leading)
                Text("Input").frame(width: 45, alignment: .trailing)
                Text("Output").frame(width: 45, alignment: .trailing)
                Text("Cache+").frame(width: 47, alignment: .trailing)
                Text("Cache-").frame(width: 47, alignment: .trailing)
                Text("Cost").frame(width: 50, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
            .padding(.bottom, 3)

            Divider()

            ForEach(models) { model in
                HStack(spacing: 0) {
                    HStack(spacing: 4) {
                        Circle().fill(modelColor(model.model)).frame(width: 5, height: 5)
                        Text(shortModelName(model.model))
                    }
                    .frame(width: 55, alignment: .leading)
                    Text(abbreviateNumber(model.inputTokens)).frame(width: 45, alignment: .trailing)
                    Text(abbreviateNumber(model.outputTokens)).frame(width: 45, alignment: .trailing)
                    Text(abbreviateNumber(model.cacheCreationTotalTokens)).frame(width: 47, alignment: .trailing)
                    Text(abbreviateNumber(model.cacheReadTokens)).frame(width: 47, alignment: .trailing)
                    Text(abbreviateCost(model.cost)).frame(width: 50, alignment: .trailing)
                }
                .font(.caption2)
                .padding(.vertical, 2)
            }

            if models.count > 1 {
                let totalIn = models.reduce(0) { $0 + $1.inputTokens }
                let totalOut = models.reduce(0) { $0 + $1.outputTokens }
                let totalCC = models.reduce(0) { $0 + $1.cacheCreationTotalTokens }
                let totalCR = models.reduce(0) { $0 + $1.cacheReadTokens }

                Divider().padding(.top, 1)
                HStack(spacing: 0) {
                    Text("Total").frame(width: 55, alignment: .leading)
                    Text(abbreviateNumber(totalIn)).frame(width: 45, alignment: .trailing)
                    Text(abbreviateNumber(totalOut)).frame(width: 45, alignment: .trailing)
                    Text(abbreviateNumber(totalCC)).frame(width: 47, alignment: .trailing)
                    Text(abbreviateNumber(totalCR)).frame(width: 47, alignment: .trailing)
                    Text(abbreviateCost(totalCost)).frame(width: 50, alignment: .trailing)
                }
                .font(.caption2)
                .fontWeight(.medium)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Helpers

    private func modelColor(_ model: String) -> Color {
        let lower = model.lowercased()
        if lower.contains("opus") { return .purple }
        if lower.contains("sonnet") { return .blue }
        if lower.contains("haiku") { return .green }
        return .gray
    }

    private func shortModelName(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("opus") { return "Opus" }
        if lower.contains("sonnet") { return "Sonnet" }
        if lower.contains("haiku") { return "Haiku" }
        return model
    }

    private func abbreviateNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func abbreviateCost(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.2f", cost) }
        if cost >= 0.01 { return String(format: "$%.3f", cost) }
        return String(format: "$%.4f", cost)
    }
}

// MARK: - Usage Window Row

struct UsageWindowRow: View {
    let title: LocalizedStringKey
    let utilization: Double
    let countdown: String?
    var exhaustEstimate: (text: String, willExhaust: Bool)? = nil

    @State private var animatedWidth: CGFloat = 0

    private var color: Color {
        Theme.utilizationColor(utilization)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let estimate = exhaustEstimate {
                    Text(estimate.willExhaust ? "usage.exhaustShort \(estimate.text)" : "usage.safeShort \(estimate.text)")
                        .font(.caption2)
                        .foregroundStyle(estimate.willExhaust ? .red : .green)
                }
                Spacer()
                Text("\(Int(utilization))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(Theme.quickSpring, value: utilization)
                if let countdown {
                    Text("usage.resetsIn \(countdown)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.15))
                    Capsule()
                        .fill(Theme.utilizationGradient(utilization))
                        .frame(width: animatedWidth)
                        .shadow(color: utilization >= 80 ? color.opacity(0.4) : .clear, radius: 4)
                }
                .onAppear {
                    withAnimation(Theme.springAnimation) {
                        animatedWidth = max(0, geo.size.width * min(utilization / 100.0, 1.0))
                    }
                }
                .onChange(of: utilization) { _, newValue in
                    withAnimation(Theme.springAnimation) {
                        animatedWidth = max(0, geo.size.width * min(newValue / 100.0, 1.0))
                    }
                }
            }
            .frame(height: Theme.progressBarHeight)
        }
    }
}
