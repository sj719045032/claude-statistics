import SwiftUI
import ClaudeStatisticsKit

struct RecentSessionRow: View {
    let session: Session
    let quickStats: SessionQuickStats?
    let cachedStats: SessionStats?
    let isSelected: Bool
    let onTap: () -> Void
    let onNewSession: () -> Void
    let onResume: () -> Void
    var onViewTranscript: (() -> Void)? = nil
    @State private var isHovered = false

    private var title: String {
        TitleSanitizer.sanitize(quickStats?.topic)
            ?? TitleSanitizer.sanitize(quickStats?.sessionName)
            ?? String(localized: "session.untitled")
    }

    private var shortPath: String {
        let home = NSHomeDirectory()
        let path = session.cwd ?? session.displayName
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                // Line 1: title + model badge
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .help(title)

                    if let model = cachedStats?.model ?? quickStats?.model {
                        Text(shortModel(model))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.modelBadgeForeground(for: model))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.modelBadgeBackground(for: model))
                            .cornerRadius(Theme.badgeRadius)
                    }

                    if isHovered {
                        CopyButton(text: session.displayName, help: "detail.copyPath")
                    }
                }

                // Line 2: project path · date · messages · tokens · cost · context%
                HStack(spacing: 8) {
                    Label(shortPath, systemImage: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

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
                            let pct = stats.contextUsagePercent
                            let color: Color = pct >= 80 ? .red : pct >= 50 ? .orange : .green
                            Text(String(format: "%.0f%%", pct))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(color)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(color.opacity(0.1))
                                .cornerRadius(3)
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
            }

            Spacer()

            if isHovered {
                if let onViewTranscript {
                    Button(action: onViewTranscript) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.hoverScale)
                    .help("session.transcript.help")
                }

                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.hoverScale)
                .help("session.new.help")

                Button(action: onResume) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.hoverScale)
                .help("session.resume.help")
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.blue.opacity(0.12) : isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .overlay(alignment: .leading) {
            if isHovered {
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
}
