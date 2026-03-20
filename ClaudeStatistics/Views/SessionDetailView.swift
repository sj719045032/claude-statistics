import SwiftUI
import AppKit

struct SessionDetailView: View {
    let session: Session
    let stats: SessionStats?
    let isLoading: Bool
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.blue)

                Spacer()

                Button(action: { TerminalLauncher.openSession(session) }) {
                    Label("Resume", systemImage: "terminal")
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        Text(session.id)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }

                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Parsing...")
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
            }
        }
    }

    @ViewBuilder
    private func statsContent(_ stats: SessionStats) -> some View {
        // Overview row
        SectionCard {
            HStack(spacing: 16) {
                InfoCell(title: "Model", value: displayModel(stats.model), icon: "cpu")
                Divider().frame(height: 28)
                if let duration = stats.duration {
                    InfoCell(title: "Duration", value: TimeFormatter.duration(duration), icon: "clock")
                    Divider().frame(height: 28)
                }
                InfoCell(title: "Size", value: TimeFormatter.fileSize(session.fileSize), icon: "doc")
            }
        }

        if let start = stats.startTime {
            SectionCard {
                HStack(spacing: 16) {
                    InfoCell(title: "Started", value: TimeFormatter.absoluteDate(start), icon: "calendar")
                    if let prompt = stats.lastPrompt, !prompt.isEmpty {
                        Divider().frame(height: 28)
                        InfoCell(title: "Last Prompt", value: prompt, icon: "text.bubble")
                    }
                }
            }
        }

        // Cost card
        SectionCard {
            VStack(spacing: 8) {
                HStack {
                    Label("Estimated Cost", systemImage: "dollarsign.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 2) {
                        if stats.isCostEstimated {
                            Text("~")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                        Text(formatCost(stats.estimatedCost))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(costColor(stats.estimatedCost))
                    }
                }

                Divider()

                let pricing = ModelPricing.pricing(for: stats.model)
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    costGridRow("Input", tokens: stats.totalInputTokens, rate: pricing.input)
                    costGridRow("Output", tokens: stats.totalOutputTokens, rate: pricing.output)
                    if stats.cacheCreation5mTokens > 0 {
                        costGridRow("Cache 5m", tokens: stats.cacheCreation5mTokens, rate: pricing.cacheWrite5m)
                    }
                    if stats.cacheCreation1hTokens > 0 {
                        costGridRow("Cache 1h", tokens: stats.cacheCreation1hTokens, rate: pricing.cacheWrite1h)
                    }
                    // Fallback: show total if no 5m/1h breakdown
                    if stats.cacheCreation5mTokens == 0 && stats.cacheCreation1hTokens == 0 && stats.cacheCreationTotalTokens > 0 {
                        costGridRow("Cache Write", tokens: stats.cacheCreationTotalTokens, rate: pricing.cacheWrite1h)
                    }
                    if stats.cacheReadTokens > 0 {
                        costGridRow("Cache Read", tokens: stats.cacheReadTokens, rate: pricing.cacheRead)
                    }
                }
            }
        }

        // Tokens card
        SectionCard {
            VStack(spacing: 6) {
                HStack {
                    Label("Tokens", systemImage: "number")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(TimeFormatter.tokenCount(stats.totalTokens))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                }

                Divider()

                TokenBar(
                    segments: tokenSegments(stats),
                    total: stats.totalTokens
                )

                // Legend
                HStack(spacing: 12) {
                    TokenLegend(color: .blue, label: "Input", value: TimeFormatter.tokenCount(stats.totalInputTokens))
                    TokenLegend(color: .green, label: "Output", value: TimeFormatter.tokenCount(stats.totalOutputTokens))
                    if stats.cacheCreation5mTokens > 0 {
                        TokenLegend(color: .yellow, label: "Cache 5m", value: TimeFormatter.tokenCount(stats.cacheCreation5mTokens))
                    }
                    if stats.cacheCreation1hTokens > 0 {
                        TokenLegend(color: .orange, label: "Cache 1h", value: TimeFormatter.tokenCount(stats.cacheCreation1hTokens))
                    }
                    if stats.cacheCreation5mTokens == 0 && stats.cacheCreation1hTokens == 0 && stats.cacheCreationTotalTokens > 0 {
                        TokenLegend(color: .orange, label: "Cache W", value: TimeFormatter.tokenCount(stats.cacheCreationTotalTokens))
                    }
                    if stats.cacheReadTokens > 0 {
                        TokenLegend(color: .purple, label: "Cache R", value: TimeFormatter.tokenCount(stats.cacheReadTokens))
                    }
                }
                .font(.system(size: 10))
            }
        }

        // Messages card
        SectionCard {
            HStack(spacing: 16) {
                InfoCell(title: "Messages", value: "\(stats.messageCount)", icon: "message")
                Divider().frame(height: 28)
                InfoCell(title: "User", value: "\(stats.userMessageCount)", icon: "person")
                Divider().frame(height: 28)
                InfoCell(title: "Assistant", value: "\(stats.assistantMessageCount)", icon: "brain")
            }
        }

        // Tool usage card
        if !stats.toolUseCounts.isEmpty {
            SectionCard {
                VStack(spacing: 6) {
                    HStack {
                        Label("Tools", systemImage: "wrench.and.screwdriver")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(stats.toolUseTotal) calls")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Divider()

                    let maxCount = stats.sortedToolUses.first?.count ?? 1
                    ForEach(stats.sortedToolUses, id: \.name) { tool in
                        HStack(spacing: 8) {
                            Text(tool.name)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .frame(width: 100, alignment: .leading)

                            ProgressView(value: Double(tool.count), total: Double(maxCount))
                                .tint(Color.blue.opacity(0.7))

                            Text("\(tool.count)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 35, alignment: .trailing)
                        }
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

    private func costGridRow(_ label: String, tokens: Int, rate: Double) -> some View {
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

// MARK: - Components

struct SectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(10)
        .background(.background.opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
        .cornerRadius(8)
    }
}

struct InfoCell: View {
    let title: String
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

struct TokenLegend: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color.opacity(0.7))
                .frame(width: 6, height: 6)
            Text("\(label): \(value)")
                .foregroundStyle(.secondary)
        }
    }
}
