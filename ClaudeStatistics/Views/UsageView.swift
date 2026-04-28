import SwiftUI
import ClaudeStatisticsKit

/// Reusable formatters for the header and chart-window labels. Kept here as
/// `static let` so we don't allocate a fresh `DateFormatter` on every body
/// pass — `compactUpdatedText` and `windowTimeRange` are called per render
/// of the usage panel header and each visible chart.
fileprivate enum UsageDateFormatters {
    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()
    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd"
        return f
    }()
}

struct UsageView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var profileViewModel: ProfileViewModel
    @ObservedObject var store: SessionDataStore
    @State private var selectedWindowTab: UsageWindowTab = .fiveHour
    @State private var selectedTrendWindowID: String = ""

    private var usagePresentation: ProviderUsagePresentation {
        store.provider.usagePresentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let usage = viewModel.usageData {
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                switch usagePresentation.displayMode {
                case .windows:
                    windowsContent(usage)
                case .quotaBuckets:
                    quotaBucketsContent(usage)
                }
            } else if !viewModel.isLoading {
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

                localTrendContent(usage: nil)
            }
        }
        .textSelection(.enabled)
        .onAppear {
            ensureValidSelectedWindow()
            ensureValidSelectedTrendWindow()
        }
        .task(id: store.provider.kind) {
            if store.provider.capabilities.supportsProfile {
                await profileViewModel.loadProfile()
            }
        }
        .onChange(of: viewModel.usageData) { _, _ in
            ensureValidSelectedWindow()
            ensureValidSelectedTrendWindow()
        }
    }
}

extension UsageView {
    enum UsageWindowTab: Hashable {
        case fiveHour
        case sevenDay
        case sevenDayOpus
        case sevenDaySonnet
    }

    struct WindowTrendInfo {
        let dataPoints: [TrendDataPoint]
        let granularity: TrendGranularity
        let windowStart: Date
        let windowEnd: Date
        let modelBreakdown: [ModelUsage]
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("usage.title")
                .font(.system(size: 15, weight: .bold))

            accountSwitcher

            Spacer()

            if let fetchedAt = viewModel.lastFetchedAt {
                Text("usage.updated \(compactUpdatedText(fetchedAt))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .help(TimeFormatter.absoluteDate(fetchedAt))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
    }

    @ViewBuilder
    private var accountSwitcher: some View {
        if profileViewModel.profileLoading {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 24, height: 24)
        } else if let uiProvider = store.provider as? any ProviderAccountUIProviding {
            uiProvider.makeAccountCardAccessory(
                context: ProviderSettingsContext(
                    appState: appState,
                    profileViewModel: profileViewModel,
                    providerKind: store.provider.kind
                ),
                triggerStyle: accountSwitcherTriggerStyle
            )
        }
    }

    private var accountSwitcherTriggerStyle: AccountSwitcherTriggerStyle {
        if let profile = profileViewModel.userProfile,
           let label = usageAccountSummaryText(for: profile) {
            return .chip(label: label, avatarInitial: usageAccountAvatarInitial(for: profile))
        }
        return .icon
    }

    private func usageAccountSummaryText(for profile: UserProfile) -> String? {
        if let email = profile.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return email
        }

        let displayName = profile.account?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullName = profile.account?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines)

        return [displayName, fullName]
            .compactMap { value -> String? in
                guard let value else { return nil }
                return value.isEmpty ? nil : value
            }
            .first
    }

    private func usageAccountAvatarInitial(for profile: UserProfile) -> String {
        let source = profile.account?.displayName
            ?? profile.account?.fullName
            ?? profile.account?.email
            ?? store.provider.displayName
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return String(store.provider.displayName.prefix(1)) }
        return String(first).uppercased()
    }

    @ViewBuilder
    private func windowsContent(_ usage: UsageData) -> some View {
        if let shortWindow = usage.fiveHour,
           let shortPresentation = usagePresentation.shortWindow {
            UsageWindowRow(
                title: LocalizedStringKey(shortPresentation.titleLocalizationKey),
                utilization: shortWindow.utilization,
                countdown: viewModel.fiveHourResetCountdown,
                exhaustEstimate: shortPresentation.showsExhaustEstimate ? viewModel.fiveHourExhaustEstimate : nil
            )
        }

        if let longWindow = usage.sevenDay,
           let longPresentation = usagePresentation.longWindow {
            UsageWindowRow(
                title: LocalizedStringKey(longPresentation.titleLocalizationKey),
                utilization: longWindow.utilization,
                countdown: viewModel.sevenDayResetCountdown,
                exhaustEstimate: longPresentation.showsExhaustEstimate ? viewModel.sevenDayExhaustEstimate : nil
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

        let tabs = availableWindowTabs(for: usage)
        if !tabs.isEmpty {
            Divider()

            Picker("", selection: $selectedWindowTab) {
                ForEach(tabs, id: \.self) { tab in
                    Text(windowTabLabel(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch selectedWindowTab {
            case .fiveHour:
                if let descriptor = usagePresentation.shortWindow {
                    windowChart(
                        for: usage.fiveHour,
                        descriptor: descriptor,
                        modelFilter: defaultUsageModelFilter
                    )
                }
            case .sevenDay:
                if let descriptor = usagePresentation.longWindow {
                    windowChart(
                        for: usage.sevenDay,
                        descriptor: descriptor,
                        modelFilter: defaultUsageModelFilter
                    )
                }
            case .sevenDayOpus:
                windowChart(
                    for: usage.sevenDayOpus,
                    descriptor: ProviderUsageWindowPresentation(
                        titleLocalizationKey: "usage.7dayOpus",
                        tabLabel: "7d Opus",
                        durationValue: -7,
                        durationComponent: .day,
                        granularity: .hour,
                        showsExhaustEstimate: true,
                        showsChart: true
                    ),
                    modelFilter: isOpus
                )
            case .sevenDaySonnet:
                windowChart(
                    for: usage.sevenDaySonnet,
                    descriptor: ProviderUsageWindowPresentation(
                        titleLocalizationKey: "usage.7daySonnet",
                        tabLabel: "7d Sonnet",
                        durationValue: -7,
                        durationComponent: .day,
                        granularity: .hour,
                        showsExhaustEstimate: true,
                        showsChart: true
                    ),
                    modelFilter: isSonnet
                )
            }
        }
    }

    @ViewBuilder
    private func quotaBucketsContent(_ usage: UsageData) -> some View {
        let buckets = usage.providerBuckets ?? []

        if buckets.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("usage.noData")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 12) {
                ForEach(buckets) { bucket in
                    UsageQuotaBucketRow(bucket: bucket)
                }
            }
        }

        localTrendContent(usage: usage)
    }

    private func windowTrendInfo(
        for window: UsageWindow?,
        descriptor: ProviderUsageWindowPresentation,
        modelFilter: ((String) -> Bool)? = nil
    ) -> WindowTrendInfo? {
        guard store.isFullParseComplete,
              let window,
              let resetAt = window.resetsAtDate,
              let start = Calendar.current.date(byAdding: descriptor.durationComponent, value: descriptor.durationValue, to: resetAt) else {
            return nil
        }

        let snapshotTime = min(viewModel.lastFetchedAt ?? Date(), resetAt)
        guard start < snapshotTime else { return nil }

        let data = store.aggregateWindowTrendData(
            from: start,
            to: snapshotTime,
            granularity: descriptor.granularity,
            cumulative: true,
            modelFilter: modelFilter
        )
        let models = store.windowModelBreakdown(from: start, to: snapshotTime, modelFilter: modelFilter)
        return data.isEmpty ? nil : WindowTrendInfo(
            dataPoints: data,
            granularity: descriptor.granularity,
            windowStart: start,
            windowEnd: resetAt,
            modelBreakdown: models
        )
    }

    private func localTrendInfo(for descriptor: ProviderUsageTrendPresentation, usage: UsageData?) -> WindowTrendInfo? {
        let range = localTrendRange(for: descriptor, usage: usage)
        let dataEnd = min(Date(), range.windowEnd)
        guard store.isFullParseComplete,
              range.windowStart < dataEnd else {
            return nil
        }

        let filter: ((String) -> Bool)? = {
            if let family = descriptor.modelFamily {
                return { model in
                    let lower = model.lowercased()
                    if family == "flash" {
                        return lower.contains("flash") && !lower.contains("lite")
                    }
                    if family == "flash-lite" {
                        return lower.contains("flash-lite")
                    }
                    return lower.contains(family.lowercased())
                }
            }
            return defaultUsageModelFilter
        }()

        let data = store.aggregateWindowTrendData(
            from: range.windowStart,
            to: dataEnd,
            granularity: descriptor.granularity,
            cumulative: true,
            modelFilter: filter
        )
        let models = store.windowModelBreakdown(from: range.windowStart, to: dataEnd, modelFilter: filter)
        return WindowTrendInfo(
            dataPoints: data,
            granularity: descriptor.granularity,
            windowStart: range.windowStart,
            windowEnd: range.windowEnd,
            modelBreakdown: models
        )
    }

    @ViewBuilder
    private func localTrendContent(usage: UsageData?) -> some View {
        let trendWindows = usagePresentation.localTrendWindows
        if !trendWindows.isEmpty {
            Divider()

            if trendWindows.count > 1 {
                Picker("", selection: $selectedTrendWindowID) {
                    ForEach(trendWindows) { window in
                        Text(window.tabLabel).tag(window.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let descriptor = selectedLocalTrendWindow ?? trendWindows.first {
                Text(LocalizedStringKey(descriptor.titleLocalizationKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let info = localTrendInfo(for: descriptor, usage: usage) {
                    windowTimeRange(info)
                    UsageTrendChartView(
                        dataPoints: info.dataPoints,
                        granularity: info.granularity,
                        windowStart: info.windowStart,
                        windowEnd: info.windowEnd
                    )
                    if !info.modelBreakdown.isEmpty {
                        CostModelsCard(models: info.modelBreakdown)
                    }
                } else {
                    let range = localTrendRange(for: descriptor, usage: usage)
                    windowTimeRange(WindowTrendInfo(
                        dataPoints: [],
                        granularity: descriptor.granularity,
                        windowStart: range.windowStart,
                        windowEnd: range.windowEnd,
                        modelBreakdown: []
                    ))
                    UsageTrendChartView(
                        dataPoints: [],
                        granularity: descriptor.granularity,
                        windowStart: range.windowStart,
                        windowEnd: range.windowEnd
                    )
                }
            }
        }
    }

    private func localTrendRange(
        for descriptor: ProviderUsageTrendPresentation,
        usage: UsageData?
    ) -> (windowStart: Date, windowEnd: Date) {
        let now = Date()
        let windowEnd: Date
        switch descriptor.anchor {
        case .now:
            windowEnd = now
        case .quotaReset:
            windowEnd = quotaResetAnchor(for: descriptor, from: usage) ?? now
        }

        let windowStart = Calendar.current.date(
            byAdding: descriptor.durationComponent,
            value: descriptor.durationValue,
            to: windowEnd
        ) ?? now
        return (windowStart, windowEnd)
    }

    private func quotaResetAnchor(for descriptor: ProviderUsageTrendPresentation, from usage: UsageData?) -> Date? {
        guard let buckets = usage?.providerBuckets else { return nil }

        let targetBuckets: [ProviderUsageBucket]
        if let family = descriptor.modelFamily {
            targetBuckets = buckets.filter { bucket in
                let lower = bucket.id.lowercased()
                if family == "flash" {
                    return lower.contains("flash") && !lower.contains("lite")
                }
                if family == "flash-lite" {
                    return lower.contains("flash-lite")
                }
                return lower.contains(family.lowercased())
            }
        } else {
            targetBuckets = buckets
        }

        let bucketsToSearch = targetBuckets.isEmpty ? buckets : targetBuckets

        let futureResets = bucketsToSearch
            .compactMap(\.resetsAtDate)
            .filter { $0 > Date() }

        if let latestFutureReset = futureResets.max() {
            return latestFutureReset
        }

        return bucketsToSearch.compactMap(\.resetsAtDate).max()
    }

    private func windowTabLabel(for tab: UsageWindowTab) -> String {
        switch tab {
        case .fiveHour:
            return usagePresentation.shortWindow?.tabLabel ?? "5h"
        case .sevenDay:
            return usagePresentation.longWindow?.tabLabel ?? "7d"
        case .sevenDayOpus:
            return "7d Opus"
        case .sevenDaySonnet:
            return "7d Sonnet"
        }
    }

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

        if usage.fiveHour != nil, usagePresentation.shortWindow?.showsChart == true {
            tabs.append(.fiveHour)
        }
        if usage.sevenDay != nil, usagePresentation.longWindow?.showsChart == true {
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

    private var selectedLocalTrendWindow: ProviderUsageTrendPresentation? {
        usagePresentation.localTrendWindows.first { $0.id == selectedTrendWindowID }
    }

    private func compactUpdatedText(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return UsageDateFormatters.timeOnly.string(from: date)
        }
        return UsageDateFormatters.dateTime.string(from: date)
    }

    private func ensureValidSelectedWindow() {
        guard let usage = viewModel.usageData else { return }
        let tabs = availableWindowTabs(for: usage)
        guard !tabs.isEmpty else { return }
        if !tabs.contains(selectedWindowTab) {
            selectedWindowTab = tabs[0]
        }
    }

    private func ensureValidSelectedTrendWindow() {
        let trendWindows = usagePresentation.localTrendWindows
        guard !trendWindows.isEmpty else { return }
        if !trendWindows.contains(where: { $0.id == selectedTrendWindowID }) {
            selectedTrendWindowID = trendWindows[0].id
        }
    }

    @ViewBuilder
    private func windowChart(
        for window: UsageWindow?,
        descriptor: ProviderUsageWindowPresentation,
        modelFilter: ((String) -> Bool)?
    ) -> some View {
        if let info = windowTrendInfo(for: window, descriptor: descriptor, modelFilter: modelFilter) {
            windowTimeRange(info)
            UsageTrendChartView(dataPoints: info.dataPoints, granularity: info.granularity, windowStart: info.windowStart, windowEnd: info.windowEnd)
            if !info.modelBreakdown.isEmpty {
                CostModelsCard(models: info.modelBreakdown)
            }
        }
    }

    private func windowTimeRange(_ info: WindowTrendInfo) -> some View {
        let startStr = formatWindowTime(info.windowStart)
        let endStr = formatWindowTime(info.windowEnd)
        return Text("\(startStr) — \(endStr)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func formatWindowTime(_ date: Date) -> String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        if comps.hour == 0 && (comps.minute ?? 0) == 0 {
            let prevDay = cal.date(byAdding: .day, value: -1, to: date)!
            return UsageDateFormatters.dateOnly.string(from: prevDay) + " 24:00"
        }
        return UsageDateFormatters.dateTime.string(from: date)
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
