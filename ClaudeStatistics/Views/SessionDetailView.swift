import SwiftUI
import ClaudeStatisticsKit
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
    let resumeCommand: String
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
                            CopyButton(text: resumeCommand, help: "detail.copyResumeCommand")
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
                    ForEach(stats.sortedToolUses, id: \.name) { tool in
                        ToolBarRow(name: tool.name, count: tool.count, maxCount: maxCount)
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
