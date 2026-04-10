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

                RefreshIconButton(isLoading: viewModel.isLoading) {
                    Task { await viewModel.forceRefresh() }
                }
                .help("usage.refresh")
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
                    countdown: viewModel.sevenDayResetCountdown
                )

                if let opus = usage.sevenDayOpus {
                    UsageWindowRow(
                        title: "usage.7dayOpus",
                        utilization: opus.utilization,
                        countdown: opus.timeUntilReset.map { TimeFormatter.countdown(from: $0) }
                    )
                }

                if let sonnet = usage.sevenDaySonnet {
                    UsageWindowRow(
                        title: "usage.7daySonnet",
                        utilization: sonnet.utilization,
                        countdown: sonnet.timeUntilReset.map { TimeFormatter.countdown(from: $0) }
                    )
                }

                if let extra = usage.extraUsage, extra.isEnabled == true {
                    Divider()
                    HStack {
                        Text("usage.extraUsage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let used = extra.usedCredits, let limit = extra.monthlyLimit {
                            Text("$\(String(format: "%.2f", used)) / $\(String(format: "%.0f", limit))")
                                .font(.caption)
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
                    windowChart(for: usage.sevenDay, durationValue: -7, durationComponent: .day, granularity: .hour, modelFilter: isClaudeNonSonnet)
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
                windowModelBreakdownView(info.modelBreakdown)
            }
        }
    }

    @ViewBuilder
    private func windowModelBreakdownView(_ models: [ModelUsage]) -> some View {
        let totalTokens = models.reduce(0) { $0 + $1.totalTokens }
        let totalCost = models.reduce(0.0) { $0 + $1.cost }

        VStack(alignment: .leading, spacing: 5) {
            // Summary line
            HStack {
                HStack(spacing: 3) {
                    Text("Tokens")
                        .foregroundStyle(.tertiary)
                    Text(abbreviateNumber(totalTokens))
                        .foregroundStyle(.blue)
                }
                Spacer()
                HStack(spacing: 3) {
                    Text("Cost")
                        .foregroundStyle(.tertiary)
                    Text(abbreviateCost(totalCost))
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)

            // Stacked bar
            if totalTokens > 0 {
                Canvas { ctx, size in
                    var x: CGFloat = 0
                    for model in models {
                        let fraction = CGFloat(model.totalTokens) / CGFloat(totalTokens)
                        let w = size.width * fraction
                        ctx.fill(Path(CGRect(x: x, y: 0, width: w, height: size.height)),
                                 with: .color(modelColor(model.model)))
                        x += w
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())
            }

            // Inline legend
            HStack(spacing: 10) {
                ForEach(models) { model in
                    let pct = totalTokens > 0 ? Double(model.totalTokens) / Double(totalTokens) * 100 : 0
                    HStack(spacing: 3) {
                        Circle().fill(modelColor(model.model)).frame(width: 6, height: 6)
                        Text(shortModelName(model.model))
                            .font(.caption2)
                        Text("\(abbreviateNumber(model.totalTokens)) (\(String(format: "%.0f", pct))%)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .padding(.top, 4)
    }

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

struct RefreshIconButton: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(isLoading ? 0 : 1)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .opacity(isLoading ? 1 : 0)
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isLoading)
    }
}

struct UsageCardContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct InlineUsageProgressRow: View {
    let title: LocalizedStringKey
    let utilization: Double
    let countdown: String?

    private var color: Color {
        if utilization >= 80 { return .red }
        if utilization >= 50 { return .orange }
        return .green
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let countdown {
                    Text("usage.resetsIn \(countdown)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                Text("\(Int(utilization))%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .frame(width: 42, alignment: .trailing)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.gray.opacity(0.2))
                        Capsule()
                            .fill(color.opacity(0.82))
                            .frame(width: geo.size.width * min(utilization / 100.0, 1.0))
                    }
                }
                .frame(width: 140, height: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
