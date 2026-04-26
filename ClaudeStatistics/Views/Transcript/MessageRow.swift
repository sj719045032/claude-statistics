import SwiftUI
import ClaudeStatisticsKit
import MarkdownView

// MARK: - MessageRow (user / assistant)

struct MessageRow: View {
    let message: TranscriptDisplayMessage
    let searchText: String
    let isCurrentMatch: Bool
    let assistantName: String

    private static let truncateThreshold = 500
    @State private var isFullExpanded = false

    private var isLong: Bool {
        message.text.count > Self.truncateThreshold
    }


    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.role == "user" ? "person.circle.fill" : "brain")
                .font(.system(size: 14))
                .foregroundStyle(message.role == "user" ? .blue : .purple)
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                    Text(message.role == "user" ? "You" : assistantName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(message.role == "user" ? .blue : .purple)
                    if let ts = message.timestamp {
                        Text(TimeFormatter.absoluteTime(ts))
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }

                // Current search match: markdown with highlighted matches as yellow inline code
                if isCurrentMatch && !searchText.isEmpty {
                    MarkdownView(SearchUtils.markdownWithHighlights(message.text, query: searchText))
                        .markdownFonts()
                        .foregroundStyle(.primary.opacity(0.85))
                        .tint(.yellow, for: .inlineCodeBlock)
                }
                // Other search matches: highlighted with truncation
                else if !searchText.isEmpty && SearchUtils.textMatches(query: searchText, in: message.text) {
                    let stripped = SearchUtils.stripMarkdown(message.text)
                    SearchUtils.highlightedText(isLong && !isFullExpanded ? String(stripped.prefix(Self.truncateThreshold)) + "…" : stripped, query: searchText)
                        .font(.system(size: 11))
                }
                // Assistant: markdown
                else if message.role == "assistant" {
                    if isLong && !isFullExpanded {
                        Text(String(message.text.prefix(Self.truncateThreshold)) + "…")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.85))
                    } else {
                        MarkdownView(message.text)
                            .markdownFonts()
                            .foregroundStyle(.primary.opacity(0.85))
                    }
                }
                // User: plain text
                else {
                    Text(message.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.85))
                }

                // Inline images
                ForEach(message.imagePaths, id: \.self) { path in
                    InlineImageView(path: path)
                }

                // Expand/collapse for long messages
                if isLong && !isCurrentMatch {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isFullExpanded.toggle() } }) {
                        Text(isFullExpanded ? "▲ Collapse" : "▼ Show all (\(message.text.count) chars)")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isCurrentMatch ? Color.clear :
            Color.clear
        )
        .overlay(alignment: .leading) {
            if isCurrentMatch {
                Rectangle().fill(Color.orange).frame(width: 4)
            }
        }
    }
}
