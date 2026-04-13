import SwiftUI

struct UsageView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var store: SessionDataStore
    @State private var selectedWindowTab: UsageWindowTab = .fiveHour

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("usage.title")
                    .font(.headline)
                Spacer()
                if let dashboardURL = viewModel.dashboardURL {
                    Button(action: {
                        NSWorkspace.shared.open(dashboardURL)
                    }) {
                        Image(systemName: "safari")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.hoverScale)
                    .foregroundStyle(.secondary)
                    .help("usage.viewOnline")
                }

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
                let tabs = availableWindowTabs(for: usage)

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                if let fiveHour = usage.fiveHour {
                    UsageWindowRow(
                        title: "usage.5hour",
                        utilization: fiveHour.utilization,
                        countdown: viewModel.fiveHourResetCountdown,
                        exhaustEstimate: viewModel.fiveHourExhaustEstimate
                    )
                }

                if let sevenDay = usage.sevenDay {
                    UsageWindowRow(
                        title: "usage.7day",
                        utilization: sevenDay.utilization,
                        countdown: viewModel.sevenDayResetCountdown,
                        exhaustEstimate: viewModel.sevenDayExhaustEstimate
                    )
                }

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


                Divider()

                if !tabs.isEmpty {
                    Picker("", selection: $selectedWindowTab) {
                        ForEach(tabs, id: \.self) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch selectedWindowTab {
                    case .fiveHour:
                        windowChart(for: usage.fiveHour, durationValue: -5, durationComponent: .hour, granularity: .fiveMinute, modelFilter: defaultUsageModelFilter)
                    case .sevenDay:
                        windowChart(for: usage.sevenDay, durationValue: -7, durationComponent: .day, granularity: .hour, modelFilter: defaultUsageModelFilter)
                    case .sevenDayOpus:
                        windowChart(for: usage.sevenDayOpus, durationValue: -7, durationComponent: .day, granularity: .hour, modelFilter: isOpus)
                    case .sevenDaySonnet:
                        windowChart(for: usage.sevenDaySonnet, durationValue: -7, durationComponent: .day, granularity: .hour, modelFilter: isSonnet)
                    }
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
        .onAppear { ensureValidSelectedWindow() }
        .onChange(of: viewModel.usageData) { _, _ in
            ensureValidSelectedWindow()
        }
    }
}

extension UsageView {
    enum UsageWindowTab: Hashable {
        case fiveHour
        case sevenDay
        case sevenDayOpus
        case sevenDaySonnet

        var label: String {
            switch self {
            case .fiveHour: return "5h"
            case .sevenDay: return "7d"
            case .sevenDayOpus: return "7d Opus"
            case .sevenDaySonnet: return "7d Sonnet"
            }
        }
    }

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

    private func isOpus(_ model: String) -> Bool {
        model.lowercased().contains("opus")
    }

    private func isSonnet(_ model: String) -> Bool {
        model.lowercased().contains("sonnet")
    }

    private var defaultUsageModelFilter: ((String) -> Bool)? {
        store.provider.kind == .claude ? isClaude : nil
    }

    private func availableWindowTabs(for usage: UsageData) -> [UsageWindowTab] {
        var tabs: [UsageWindowTab] = []
        if usage.fiveHour != nil {
            tabs.append(.fiveHour)
        }
        if usage.sevenDay != nil {
            tabs.append(.sevenDay)
        }
        if usage.sevenDayOpus != nil {
            tabs.append(.sevenDayOpus)
        }
        if usage.sevenDaySonnet != nil {
            tabs.append(.sevenDaySonnet)
        }
        return tabs
    }

    private func ensureValidSelectedWindow() {
        guard let usage = viewModel.usageData else { return }
        let tabs = availableWindowTabs(for: usage)
        guard !tabs.isEmpty else { return }
        if !tabs.contains(selectedWindowTab) {
            selectedWindowTab = tabs[0]
        }
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
                CostModelsCard(models: info.modelBreakdown)
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
