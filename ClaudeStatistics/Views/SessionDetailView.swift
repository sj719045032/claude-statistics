import SwiftUI
import ClaudeStatisticsKit
import AppKit

struct SessionDetailView: View {
    let session: Session
    let providerDisplayName: String
    let supportsCost: Bool
    var topic: String? = nil
    var sessionName: String? = nil
    var subagents: [Session] = []
    var subagentStats: [String: SessionStats] = [:]
    var subagentQuickStats: [String: SessionQuickStats] = [:]
    let stats: SessionStats?
    let isLoading: Bool
    let onNewSession: () -> Void
    let onResume: () -> Void
    let resumeCommand: String
    let loadTrendData: (TrendGranularity) async -> [TrendDataPoint]
    let onBack: () -> Void
    var onDelete: (() -> Void)? = nil
    var onViewTranscript: (() -> Void)? = nil
    var onOpenSubagent: ((Session) -> Void)? = nil

    @State private var showDeleteConfirm = false
    @State private var isTopicExpanded = false
    @State private var isPromptExpanded = false
    @State private var isSubagentsExpanded = false

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

                if let onDelete {
                    DestructiveIconButton(
                        action: { skipConfirm in
                            if skipConfirm {
                                onDelete()
                            } else {
                                showDeleteConfirm = true
                            }
                        },
                        size: 11
                    )
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

                if session.isResumable {
                    Button(action: onResume) {
                        Label("detail.resume", systemImage: "terminal")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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
                            Text(session.agentDisplayName ?? session.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            CopyButton(text: session.displayName, help: "detail.copyPath")
                        }
                        if session.isSubagentSession {
                            Text(session.displayName)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            Text(session.externalID)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            if session.isResumable {
                                CopyButton(text: resumeCommand, help: "detail.copyResumeCommand")
                            }
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
        .destructiveConfirmation(
            isPresented: $showDeleteConfirm,
            title: "detail.deleteConfirm"
        ) {
            onDelete?()
        }
    }

    @ViewBuilder
    private func statsContent(_ stats: SessionStats) -> some View {
        let familyMetrics = sessionFamilyMetrics(rootStats: stats)

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
                    if session.isArchived {
                        InfoCell(title: "detail.status", value: LanguageManager.localizedString("detail.status.archived"), icon: "archivebox")
                    } else {
                        InfoCell(title: "detail.size", value: TimeFormatter.fileSize(session.fileSize), icon: "doc")
                    }
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
                    CostCell(cost: familyMetrics.estimatedCost)
                    Divider().frame(height: 28)
                    TokenCell(tokens: familyMetrics.totalTokens)
                    if stats.contextTokens > 0 {
                        Divider().frame(height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Label("detail.context", systemImage: "rectangle.stack")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            HStack(spacing: 8) {
                                Text("\(TimeFormatter.tokenCount(stats.contextTokens))/\(TimeFormatter.tokenCount(stats.contextWindowSize))")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                Spacer(minLength: 2)
                                Text(String(format: "%.0f%%", stats.contextUsagePercent))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(contextColor(stats.contextUsagePercent))
                                    .fixedSize()
                            }
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Divider()
                HStack(spacing: 16) {
                    InfoCell(title: "detail.messages", value: "\(familyMetrics.messageCount)", icon: "message")
                    Divider().frame(height: 28)
                    InfoCell(title: "detail.user", value: "\(familyMetrics.userMessageCount)", icon: "person")
                    Divider().frame(height: 28)
                    InfoCell(title: "detail.assistant", value: "\(familyMetrics.assistantMessageCount)", icon: "brain")
                }
            }
        }

        if !subagents.isEmpty {
            subagentSection
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
                    ForEach(stats.sortedToolUses, id: \.name) { tool in
                        ToolBarRow(name: tool.name, count: tool.count, maxCount: maxCount)
                    }
                }
            }
        }
    }

    private var subagentSection: some View {
        SectionCard {
            VStack(spacing: 8) {
                Button {
                    withAnimation(Theme.quickSpring) {
                        isSubagentsExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Label("detail.subagents", systemImage: "person.2.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(subagents.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Image(systemName: isSubagentsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isSubagentsExpanded {
                    Divider()

                    if let metrics = SessionListMetrics.aggregate(
                        sessions: subagents,
                        parsedStats: subagentStats,
                        quickStats: subagentQuickStats
                    ) {
                        HStack(spacing: 12) {
                            Label("\(metrics.messageCount)", systemImage: "message")
                            Text(TimeFormatter.tokenCount(metrics.totalTokens))
                                .fontDesign(.monospaced)
                            if supportsCost {
                                Text(formatCost(metrics.estimatedCost))
                                    .fontWeight(.medium)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(costColor(metrics.estimatedCost))
                            }
                            Spacer()
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                        Divider()
                    }

                    ForEach(Array(subagents.enumerated()), id: \.element.id) { index, subagent in
                        subagentEntry(subagent)
                        if index < subagents.count - 1 {
                            Divider()
                                .padding(.leading, CGFloat(max(0, (subagent.agentDepth ?? 1) - 1) * 10))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func subagentEntry(_ subagent: Session) -> some View {
        if let onOpenSubagent {
            Button {
                onOpenSubagent(subagent)
            } label: {
                subagentRow(subagent, showsDisclosure: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            subagentRow(subagent, showsDisclosure: false)
        }
    }

    private func subagentRow(_ subagent: Session, showsDisclosure: Bool) -> some View {
        let fullStats = subagentStats[subagent.id]
        let quick = subagentQuickStats[subagent.id]
        let messages = fullStats?.messageCount ?? quick?.messageCount ?? 0
        let tokens = fullStats?.totalTokens ?? quick?.totalTokens ?? 0
        let cost = fullStats?.estimatedCost ?? quick?.estimatedCost ?? 0
        let title = subagent.agentDisplayName ?? String(subagent.externalID.prefix(8))
        let depth = max(1, subagent.agentDepth ?? 1)

        return HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Text("L\(depth)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if let nickname = subagent.agentNickname,
                       nickname != title {
                        Text(nickname)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    Text(TimeFormatter.relativeDate(subagent.lastModified))
                    if messages > 0 {
                        Label("\(messages)", systemImage: "message")
                    }
                    if tokens > 0 {
                        Text(TimeFormatter.tokenCount(tokens))
                            .fontDesign(.monospaced)
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if supportsCost, cost > 0 {
                Text(formatCost(cost))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(costColor(cost))
            }

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.leading, CGFloat((depth - 1) * 10))
        .help(subagent.agentPath ?? title)
    }

    private func sessionFamilyMetrics(rootStats: SessionStats) -> DetailFamilyMetrics {
        var parsedStats = subagentStats
        parsedStats[session.id] = rootStats
        let sessions = [session] + subagents
        let aggregate = SessionListMetrics.aggregate(
            sessions: sessions,
            parsedStats: parsedStats,
            quickStats: subagentQuickStats
        )

        var userMessages = rootStats.userMessageCount
        var assistantMessages = rootStats.assistantMessageCount
        for subagent in subagents {
            if let stats = parsedStats[subagent.id] {
                userMessages += stats.userMessageCount
                assistantMessages += stats.assistantMessageCount
            } else if let quick = subagentQuickStats[subagent.id] {
                userMessages += quick.userMessageCount
                assistantMessages += max(0, quick.messageCount - quick.userMessageCount)
            }
        }

        return DetailFamilyMetrics(
            messageCount: aggregate?.messageCount ?? rootStats.messageCount,
            userMessageCount: userMessages,
            assistantMessageCount: assistantMessages,
            totalTokens: aggregate?.totalTokens ?? rootStats.totalTokens,
            estimatedCost: aggregate?.estimatedCost ?? rootStats.estimatedCost
        )
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

private struct DetailFamilyMetrics {
    let messageCount: Int
    let userMessageCount: Int
    let assistantMessageCount: Int
    let totalTokens: Int
    let estimatedCost: Double
}
