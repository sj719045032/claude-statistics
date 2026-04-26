import SwiftUI
import ClaudeStatisticsKit

/// Bundle of callbacks + provider info that lets `ProjectAnalyticsView` push a
/// `SessionDetailView` inline without depending on `SessionViewModel`. The
/// owner of the view-model wires these closures (e.g. `MenuBarView` /
/// `SessionListView`) so analytics stays decoupled from session selection
/// state and can render its own ephemeral session detail without bouncing
/// through the global `selectedSession`.
struct InlineSessionDetailAdapter {
    let providerDisplayName: String
    let supportsCost: Bool
    let resumeCommand: (Session) -> String
    let loadTrendData: (Session, TrendGranularity) async -> [TrendDataPoint]
    let onNewSession: (Session) -> Void
    let onResume: (Session) -> Void
    let onDelete: (Session) -> Void
    /// Optional. When `nil` the inline `SessionDetailView` hides its
    /// transcript button. Stats-tab callers omit this because transcript
    /// rendering lives in the Sessions-tab content tree, so wiring it from
    /// stats would either produce no visual effect or force a tab switch.
    let onOpenTranscript: ((Session) -> Void)?
}

struct ProjectAnalyticsView: View {
    let group: ProjectGroup
    @ObservedObject var store: SessionDataStore
    let onBack: () -> Void
    var inlineSessionDetailAdapter: InlineSessionDetailAdapter? = nil

    @State private var modelUsages: [ModelUsage] = []
    @State private var inlineSelectedSession: Session?

    var body: some View {
        if let adapter = inlineSessionDetailAdapter,
           let session = inlineSelectedSession {
            // Inline drill-in: render SessionDetailView as if it were pushed
            // onto this navigation level. Back returns here without changing
            // the surrounding tab or the global `selectedSession`.
            SessionDetailView(
                session: session,
                providerDisplayName: adapter.providerDisplayName,
                supportsCost: adapter.supportsCost,
                topic: store.quickStats[session.id]?.topic,
                sessionName: store.quickStats[session.id]?.sessionName,
                stats: store.parsedStats[session.id],
                isLoading: false,
                onNewSession: { adapter.onNewSession(session) },
                onResume: { adapter.onResume(session) },
                resumeCommand: adapter.resumeCommand(session),
                loadTrendData: { granularity in
                    await adapter.loadTrendData(session, granularity)
                },
                onBack: {
                    withAnimation(Theme.springAnimation) {
                        inlineSelectedSession = nil
                    }
                },
                onDelete: {
                    adapter.onDelete(session)
                    inlineSelectedSession = nil
                },
                onViewTranscript: adapter.onOpenTranscript.map { handler in
                    { handler(session) }
                }
            )
        } else {
            analyticsContent
        }
    }

    private var analyticsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
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

                Text(group.shortPath)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // 1. Key Metrics
                    SectionCard {
                        VStack(spacing: 8) {
                            HStack(spacing: 16) {
                                CostCell(cost: group.totalCost)
                                Divider().frame(height: 28)
                                TokenCell(tokens: group.totalTokens)
                            }
                            Divider()
                            HStack(spacing: 16) {
                                InfoCell(title: "detail.sessions", value: "\(group.sessions.count)", icon: "list.bullet")
                                Divider().frame(height: 28)
                                InfoCell(title: "detail.messages", value: "\(group.totalMessages)", icon: "message")
                                Divider().frame(height: 28)
                                InfoCell(title: "stats.tools", value: "\(group.toolUseCount)", icon: "wrench")
                            }
                        }
                    }

                    // 2. Trend chart
                    TrendSection(
                        initialGranularity: .day,
                        loadData: { gran in
                            await store.aggregateProjectTrendData(sessions: group.sessions, granularity: gran)
                        }
                    )

                    // 3. Tokens + Models — unified breakdown
                    if !modelUsages.isEmpty {
                        CostModelsCard(models: modelUsages)
                    }

                    // 4. Top sessions (by cost). Mirrors the Top Tools card so
                    // the user can drill from project-level totals straight into
                    // the sessions driving cost. Tap routes back through the
                    // parent's session-selection state so the existing detail
                    // panel/transcript flow stays the source of truth.
                    let topSess = topSessions()
                    if !topSess.isEmpty {
                        SectionCard {
                            VStack(spacing: 6) {
                                HStack {
                                    Label("detail.topSessions", systemImage: "list.star")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(topSess.count)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                                Divider()
                                let maxCost = topSess.first?.stats.estimatedCost ?? 1
                                ForEach(Array(topSess.enumerated()), id: \.element.session.id) { index, item in
                                    TopSessionRow(
                                        session: item.session,
                                        stats: item.stats,
                                        quickStats: store.quickStats[item.session.id],
                                        maxCost: max(maxCost, 0.000001),
                                        delay: Double(index) * 0.03,
                                        onTap: inlineSessionDetailAdapter == nil ? nil : {
                                            withAnimation(Theme.springAnimation) {
                                                inlineSelectedSession = item.session
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }

                    // 5. Tools
                    if group.toolUseCount > 0 {
                        let toolCounts = aggregatedToolCounts()
                        if !toolCounts.isEmpty {
                            SectionCard {
                                VStack(spacing: 6) {
                                    HStack {
                                        Label("detail.tools", systemImage: "wrench.and.screwdriver")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("detail.calls \(group.toolUseCount)")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Divider()
                                    let maxCount = toolCounts.first?.count ?? 1
                                    ForEach(Array(toolCounts.prefix(15).enumerated()), id: \.element.name) { index, item in
                                        ToolBarRow(name: item.name, count: item.count, maxCount: maxCount, delay: Double(index) * 0.03)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .task {
            modelUsages = store.aggregateProjectModelBreakdown(sessions: group.sessions)
        }
    }

    // MARK: - Helpers

    private func aggregatedToolCounts() -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for session in group.sessions {
            guard let stats = store.parsedStats[session.id] else { continue }
            for (tool, count) in stats.toolUseCounts {
                counts[tool, default: 0] += count
            }
        }
        return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    private func topSessions() -> [(session: Session, stats: SessionStats)] {
        group.sessions
            .compactMap { session -> (session: Session, stats: SessionStats)? in
                guard let stats = store.parsedStats[session.id] else { return nil }
                return (session, stats)
            }
            .sorted { $0.stats.estimatedCost > $1.stats.estimatedCost }
            .prefix(10)
            .map { $0 }
    }
}

// MARK: - Top session row

private struct TopSessionRow: View {
    let session: Session
    let stats: SessionStats
    let quickStats: SessionQuickStats?
    let maxCost: Double
    let delay: Double
    var onTap: (() -> Void)?

    @State private var appeared = false
    @State private var isHovered = false

    private var title: String {
        quickStats?.topic ?? quickStats?.sessionName ?? session.displayName
    }

    private var modelLabel: String? {
        let model = stats.model.isEmpty ? quickStats?.model : stats.model
        guard let model, !model.isEmpty else { return nil }
        return model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-2025", with: "")
            .replacingOccurrences(of: "-2024", with: "")
    }

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(title)

                        if let modelLabel {
                            Text(modelLabel)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.modelBadgeForeground(for: stats.model))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Theme.modelBadgeBackground(for: stats.model))
                                .cornerRadius(Theme.badgeRadius)
                        }
                    }

                    HStack(spacing: 8) {
                        Label("\(stats.messageCount)", systemImage: "message")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(TimeFormatter.tokenCount(stats.totalTokens))
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
                                        ? geo.size.width * CGFloat(stats.estimatedCost / maxCost)
                                        : 0,
                                    height: 3
                                )
                        }
                    }
                    .frame(height: 3)
                }

                Text(costString(stats.estimatedCost))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.costColor(stats.estimatedCost))
                    .frame(minWidth: 60, alignment: .trailing)

                if onTap != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(isHovered && onTap != nil ? Color.primary.opacity(0.04) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .onHover { isHovered = $0 }
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
}
