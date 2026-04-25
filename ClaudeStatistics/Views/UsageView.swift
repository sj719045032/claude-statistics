import SwiftUI

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
        } else if let accountSwitcherProvider = store.provider as? any ProviderAccountCardSupplementProviding {
            accountSwitcherProvider.makeCompactAccountSwitcherAccessory(
                context: ProviderSettingsContext(appState: appState, profileViewModel: profileViewModel),
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
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
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
                    // When willExhaust=false the predicted exhaust time exceeds
                    // the refresh window — drop the "(Nd Nh left)" detail (it's
                    // unactionable and often absurd, e.g. "682d left" on a 7-day
                    // window) and just signal abundance.
                    if estimate.willExhaust {
                        Text("usage.exhaustShort \(estimate.text)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else {
                        Text("usage.safeRelaxed")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
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

struct UsageQuotaBucketRow: View {
    let bucket: ProviderUsageBucket

    @State private var animatedWidth: CGFloat = 0

    private var utilization: Double {
        100.0 - min(max(bucket.remainingPercentage, 0), 100)
    }

    private var color: Color {
        Theme.utilizationColor(utilization)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bucket.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let text = amountText {
                    Text(text)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let subtitle = bucket.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                
                Spacer()
                
                Text("\(Int(utilization.rounded()))%")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .animation(Theme.quickSpring, value: utilization)
                    
                if let resetText {
                    Text(resetText)
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

    private var amountText: String? {
        if let limit = bucket.limitAmount, let remaining = bucket.remainingAmount {
            let used = max(limit - remaining, 0)
            let usedStr = formatQuotaAmount(used)
            let limitStr = formatQuotaAmount(limit)
            if let unit = bucket.unit, !unit.isEmpty {
                return "\(usedStr)/\(limitStr) \(unit)"
            }
            return "\(usedStr)/\(limitStr)"
        }
        return nil
    }

    private func formatQuotaAmount(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.001 {
            return Int(rounded).formatted()
        }
        return String(format: "%.1f", value)
    }

    private var resetText: LocalizedStringKey? {
        guard let resetDate = bucket.resetsAtDate else { return nil }
        let interval = resetDate.timeIntervalSinceNow
        if interval <= 0 {
            return "usage.resetsNow"
        }
        return "usage.resetsIn \(TimeFormatter.countdown(from: interval))"
    }
}
