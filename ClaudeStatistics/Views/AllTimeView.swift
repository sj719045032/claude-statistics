import SwiftUI

/// The "All" tab of the Stats view.
///
/// Shows an all-time aggregated PeriodStats using the same visual vocabulary as
/// `PeriodDetailView`, minus the period-over-period deltas (nothing to compare
/// against) and the back button. Adds two all-time-only modules on top of that:
/// a GitHub-style calendar heatmap and a Top Projects list.
struct AllTimeView: View {
    let stat: PeriodStats
    @ObservedObject var store: SessionDataStore

    @State private var trendData: [TrendDataPoint] = []
    @State private var heatmapScope: CalendarHeatmap.Scope = .last12Months
    @State private var scopeMenuHovered = false
    @State private var shareButtonHovered = false

    var body: some View {
        scrollContent
    }

    // MARK: - Scrollable content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                heatmapCard
                overviewCard
                trendCard
                CostModelsCard(period: stat)
                topProjectsCard
                if !stat.toolUseCounts.isEmpty {
                    toolUsageCard
                }
            }
            .padding(12)
        }
    }

    // MARK: - Overview card (no delta — "All Time" has no prior period)

    private var overviewCard: some View {
        SectionCard {
            HStack(spacing: 12) {
                CostCell(cost: stat.totalCost)
                Divider().frame(height: 32)
                TokenCell(tokens: stat.totalTokens)
                Divider().frame(height: 32)
                overviewItem("stats.sessions", value: "\(stat.sessionCount)", icon: "list.bullet")
                Divider().frame(height: 32)
                overviewItem("stats.messages", value: "\(stat.messageCount)", icon: "message")
            }
        }
    }

    // MARK: - Trend (all-time, daily granularity)

    private var trendCard: some View {
        SectionCard {
            VStack(spacing: 8) {
                Label("detail.trend", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TrendChartView(dataPoints: trendData, granularity: .day)
            }
        }
        .task(id: stat.id) {
            trendData = store.aggregateTrendData(for: stat, periodType: .all)
        }
    }

    // MARK: - Calendar heatmap

    private var heatmapCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("allTime.activity", systemImage: "calendar")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    shareButton
                    heatmapScopeMenu
                }
                CalendarHeatmap(
                    buckets: store.dailyHeatmapData,
                    metric: .tokens,
                    scope: heatmapScope
                )
            }
        }
    }

    /// All-time share button for the current provider. Icon-only to fit beside
    /// the year picker in the heatmap card header without taking a full row.
    private var shareButton: some View {
        Button(action: openSharePreview) {
            HStack(spacing: 3) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 10, weight: .semibold))
                Text("share.action.share")
                    .font(.system(size: 10))
            }
            .foregroundStyle(Color.blue)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(shareButtonHovered ? 0.08 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { shareButtonHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: shareButtonHovered)
    }

    private func openSharePreview() {
        guard let result = store.buildAllTimeShareRoleResult() else { return }
        SharePreviewWindowController.show(result: result, source: .providerAllTime)
    }

    /// Dropdown for switching the heatmap between "last 12 months" and a
    /// specific calendar year (years derived from the actual data).
    ///
    /// Uses `Menu` with an inline `Picker` inside: the outer Menu lets us fully
    /// control the trigger label's typography (SwiftUI's font/colour modifiers
    /// don't reach through `Picker(.menu)`'s native NSPopUpButton bezel);
    /// the inline Picker gives the menu items the standard "selected ✓" affordance.
    private var heatmapScopeMenu: some View {
        Menu {
            Picker("", selection: $heatmapScope) {
                Text("allTime.heatmap.last12Months")
                    .tag(CalendarHeatmap.Scope.last12Months)
                ForEach(availableHeatmapYears, id: \.self) { year in
                    Text(String(year)).tag(CalendarHeatmap.Scope.year(year))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(heatmapScopeLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(.secondary)
        // Hover affordance is applied to the Menu's bounding box (not inside its
        // label) because macOS' internal Menu styling suppresses `.background`
        // layered inside the label.
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(scopeMenuHovered ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { scopeMenuHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: scopeMenuHovered)
        .fixedSize()
    }

    private var heatmapScopeLabel: String {
        switch heatmapScope {
        case .last12Months:
            return LanguageManager.localizedString("allTime.heatmap.last12Months")
        case .year(let y):
            return String(y)
        }
    }

    private var availableHeatmapYears: [Int] {
        let cal = Calendar.current
        let years = Set(store.dailyHeatmapData.keys.map { cal.component(.year, from: $0) })
        return years.sorted(by: >)
    }

    // MARK: - Top projects (by cost)

    private var topProjectsCard: some View {
        let top = Array(store.topProjects.prefix(10))
        return Group {
            if !top.isEmpty {
                SectionCard {
                    VStack(spacing: 6) {
                        HStack {
                            Label("allTime.topProjects", systemImage: "folder.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(top.count)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Divider()
                        let maxCost = top.first?.cost ?? 1
                        ForEach(Array(top.enumerated()), id: \.element.id) { index, proj in
                            TopProjectRow(
                                project: proj,
                                maxCost: max(maxCost, 0.000001),
                                delay: Double(index) * 0.03
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Tool usage

    private var toolUsageCard: some View {
        SectionCard {
            VStack(spacing: 6) {
                HStack {
                    Label("stats.toolUsage", systemImage: "wrench.and.screwdriver")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(stat.toolUseCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Divider()
                let sorted = stat.toolUseCounts.sorted { $0.value > $1.value }
                let maxCount = sorted.first?.value ?? 1
                ForEach(Array(sorted.prefix(15).enumerated()), id: \.element.key) { index, item in
                    ToolBarRow(name: item.key, count: item.value, maxCount: maxCount, delay: Double(index) * 0.03)
                }
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

}

// MARK: - Top project row

private struct TopProjectRow: View {
    let project: TopProject
    let maxCost: Double
    let delay: Double

    @State private var appeared = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text("\(project.sessionCount) sessions")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(TimeFormatter.tokenCount(project.tokens))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.12))
                            .frame(height: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.blue.opacity(0.55))
                            .frame(
                                width: appeared
                                    ? geo.size.width * CGFloat(project.cost / maxCost)
                                    : 0,
                                height: 3
                            )
                    }
                }
                .frame(height: 3)
            }

            Text(costString(project.cost))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(costColor(project.cost))
                .frame(minWidth: 60, alignment: .trailing)
        }
        .onAppear {
            appeared = false
            withAnimation(.easeOut(duration: 0.4).delay(delay)) {
                appeared = true
            }
        }
    }

    private func costString(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.2f", cost) }
        if cost >= 0.01 { return String(format: "$%.3f", cost) }
        return String(format: "$%.4f", cost)
    }

    private func costColor(_ cost: Double) -> Color {
        if cost > 100.0 { return .red }
        if cost > 10.0 { return .orange }
        return .green
    }
}
