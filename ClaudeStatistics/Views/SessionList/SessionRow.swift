import SwiftUI
import ClaudeStatisticsKit
import AppKit

struct SessionRow: View {
    let session: Session
    let quickStats: SessionQuickStats?
    let cachedStats: SessionStats?
    let isSelected: Bool
    let isSelecting: Bool
    let isChecked: Bool
    var grouped: Bool = false
    var searchSnippet: String? = nil
    var searchQuery: String = ""
    var onSnippetTap: (() -> Void)? = nil
    var onViewTranscript: (() -> Void)? = nil
    let onTap: () -> Void
    let onNewSession: () -> Void
    let onResume: () -> Void
    let onDelete: (Bool) -> Void
    @State private var isHovered = false

    private var primaryTitle: String {
        if grouped {
            return TitleSanitizer.sanitize(quickStats?.topic)
                ?? TitleSanitizer.sanitize(quickStats?.sessionName)
                ?? String(localized: "session.untitled")
        }
        return session.displayName
    }

    private var subtitle: String? {
        nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if isSelecting {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isChecked ? Color.blue : Color.gray.opacity(0.3))
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(primaryTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .help(primaryTitle)

                    if let model = cachedStats?.model ?? quickStats?.model {
                        Text(shortModel(model))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.modelBadgeForeground(for: model))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.modelBadgeBackground(for: model))
                            .cornerRadius(Theme.badgeRadius)
                    }

                    if isHovered && !isSelecting {
                        CopyButton(text: session.displayName, help: "detail.copyPath")
                    }
                }

                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(1)
                        .help(sub)
                }

                HStack(spacing: 8) {
                    Text(TimeFormatter.relativeDate(session.lastModified))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if let stats = cachedStats {
                        Label("\(stats.messageCount)", systemImage: "message")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(TimeFormatter.tokenCount(stats.totalTokens))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(formatCost(stats.estimatedCost))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(costColor(stats.estimatedCost))

                        if stats.contextTokens > 0 {
                            contextBadge(stats)
                        }
                    } else if let qs = quickStats, qs.messageCount > 0 {
                        Label("\(qs.messageCount)", systemImage: "message")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(TimeFormatter.fileSize(session.fileSize))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(TimeFormatter.fileSize(session.fileSize))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Search snippet from FTS content match
                if let snippet = searchSnippet {
                    Button(action: { onSnippetTap?() }) {
                        SnippetText(snippet: snippet, searchText: searchQuery)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }

            Spacer()

            if !isSelecting && isHovered {
                if !grouped {
                    Button(action: onNewSession) {
                        Image(systemName: "plus")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.hoverScale)
                    .help("session.new.help")
                }

                if let onViewTranscript {
                    Button(action: onViewTranscript) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.hoverScale)
                    .help("session.transcript.help")
                }

                Button(action: onResume) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.blue)
                }
                .buttonStyle(.hoverScale)
                .help("session.resume.help")

                DestructiveIconButton(action: onDelete)
                    .buttonStyle(.hoverScale)
            }

            if !isSelecting {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, grouped ? 20 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(
            isSelecting && isChecked ? Color.blue.opacity(0.1) :
            isSelected ? Color.blue.opacity(0.12) :
            isHovered ? Color.primary.opacity(0.04) : Color.clear
        )
        .overlay(alignment: .leading) {
            if isHovered && !isSelecting {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering in
            withAnimation(Theme.quickSpring) { isHovered = hovering }
        }
    }

    private func contextBadge(_ stats: SessionStats) -> some View {
        let pct = stats.contextUsagePercent
        let color: Color = pct >= 80 ? .red : pct >= 50 ? .orange : .green
        return Text(String(format: "%.0f%%", pct))
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color.opacity(0.1))
            .cornerRadius(3)
    }
}
