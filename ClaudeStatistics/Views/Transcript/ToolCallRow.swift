import SwiftUI
import ClaudeStatisticsKit
import MarkdownView

// MARK: - ToolCallRow

struct ToolCallRow: View {
    let message: TranscriptDisplayMessage
    let searchText: String
    let isCurrentMatch: Bool
    let providerDisplayName: String
    var sessionFilePath: String = ""
    let loadMessagesAtPath: (String) async -> [TranscriptDisplayMessage]
    @State private var isExpanded = false
    @State private var subagentMessages: [TranscriptDisplayMessage]?
    @State private var isLoadingSubagent = false

    private var toolDisplayName: String {
        switch message.toolName {
        case "Edit": return "Update"
        default: return message.toolName ?? "tool"
        }
    }

    private var toolIcon: String {
        switch message.toolName {
        case "Read": return "doc.text"
        case "Write": return "doc.text.fill"
        case "Edit": return "pencil"
        case "Bash": return "terminal"
        case "Grep": return "text.magnifyingglass"
        case "Glob": return "folder"
        case "Agent": return "person.2"
        case "TaskCreate", "TaskUpdate": return "checklist"
        case "WebSearch", "WebFetch": return "globe"
        default: return "wrench.and.screwdriver"
        }
    }

    private var toolColor: Color {
        switch message.toolName {
        case "Read": return .cyan
        case "Write": return .green
        case "Edit": return .orange
        case "Bash": return .pink
        case "Grep": return .yellow
        case "Glob": return Color(red: 0.4, green: 0.8, blue: 1.0) // light blue
        case "Agent": return Color(red: 0.7, green: 0.5, blue: 1.0) // violet
        case "TaskCreate", "TaskUpdate": return .mint
        case "WebSearch", "WebFetch": return .teal
        case "ToolSearch": return .gray
        case "AskUserQuestion": return Color(red: 1.0, green: 0.6, blue: 0.4) // coral
        default: return .gray
        }
    }

    private var hasDetail: Bool {
        if message.toolName == "Agent" { return true }
        if message.toolName == "Edit" && message.editOldString != nil { return true }
        return message.toolDetail != nil && !(message.toolDetail?.isEmpty ?? true)
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary row
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: toolIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(toolColor)
                    .frame(width: 20)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(toolDisplayName)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(toolColor)

                        if let ts = message.timestamp {
                            Text(TimeFormatter.absoluteTime(ts))
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }

                        Spacer()

                        if hasDetail {
                            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.hoverScale)
                        }
                    }

                    if !message.text.isEmpty {
                        if !searchText.isEmpty && SearchUtils.textMatches(query: searchText, in: message.text) {
                            SearchUtils.highlightedText(message.text, query: searchText)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(isExpanded ? nil : 2)
                        } else {
                            Text(message.text)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? nil : 2)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasDetail {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    // Auto-load subagent conversation on expand
                    if isExpanded && message.toolName == "Agent" && subagentMessages == nil && !isLoadingSubagent {
                        loadSubagentConversation()
                    }
                }
            }

            // Expandable detail
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if message.toolName == "Edit",
                       let oldStr = message.editOldString,
                       let newStr = message.editNewString {
                        editDiffView(oldStr: oldStr, newStr: newStr)
                    } else if let detail = message.toolDetail, !detail.isEmpty {
                        toolDetailView(detail)
                    }

                    // Subagent conversation
                    if message.toolName == "Agent" {
                        if let subMsgs = subagentMessages {
                            Divider().padding(.vertical, 2)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(subMsgs) { sub in
                                    if sub.role == "tool" {
                                        ToolCallRow(message: sub, searchText: "", isCurrentMatch: false,
                                                    providerDisplayName: providerDisplayName,
                                                    loadMessagesAtPath: loadMessagesAtPath)
                                    } else {
                                        MessageRow(message: sub, searchText: "", isCurrentMatch: false,
                                                   assistantName: providerDisplayName)
                                    }
                                }
                            }
                            .background(Color.gray.opacity(0.05))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                            )
                        } else if isLoadingSubagent {
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
                                Text("Loading...").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.leading, 40)
                .padding(.trailing, 12)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.clear
        )
        .overlay(alignment: .leading) {
            if isCurrentMatch {
                Rectangle().fill(Color.orange).frame(width: 4)
            }
        }
        .onAppear {
            if isCurrentMatch && hasDetail { isExpanded = true }
        }
        .onChange(of: isCurrentMatch) { _, isCurrent in
            if isCurrent && hasDetail { isExpanded = true }
        }
    }

    private func loadSubagentConversation() {
        guard let toolTimestamp = message.timestamp else { return }
        isLoadingSubagent = true

        Task.detached {
            let sessionId = ((sessionFilePath as NSString).lastPathComponent as NSString).deletingPathExtension
            let subDir = ((sessionFilePath as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent(sessionId).appending("/subagents")
            let fm = FileManager.default

            guard fm.fileExists(atPath: subDir),
                  let files = try? fm.contentsOfDirectory(atPath: subDir) else {
                await MainActor.run { isLoadingSubagent = false }
                return
            }

            // Find subagent file by matching first timestamp (within 1 second)
            var bestFile: String?
            var bestDiff: TimeInterval = .greatestFiniteMagnitude
            let isoFmt = ISO8601DateFormatter()
            isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoFallback = ISO8601DateFormatter()
            isoFallback.formatOptions = [.withInternetDateTime]

            for file in files where file.hasSuffix(".jsonl") {
                let path = (subDir as NSString).appendingPathComponent(file)
                guard let handle = FileHandle(forReadingAtPath: path) else { continue }
                let chunk = handle.readData(ofLength: 4096)
                handle.closeFile()
                guard let firstLine = String(data: chunk, encoding: .utf8)?.components(separatedBy: "\n").first,
                      let json = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
                      let tsStr = json["timestamp"] as? String,
                      let ts = isoFmt.date(from: tsStr) ?? isoFallback.date(from: tsStr) else { continue }

                let diff = abs(ts.timeIntervalSince(toolTimestamp))
                if diff < bestDiff {
                    bestDiff = diff
                    bestFile = path
                }
            }

            guard let matchedFile = bestFile, bestDiff < 2.0 else {
                await MainActor.run { isLoadingSubagent = false }
                return
            }

            let messages = await loadMessagesAtPath(matchedFile)
            await MainActor.run {
                subagentMessages = messages
                isLoadingSubagent = false
            }
        }
    }

    @ViewBuilder
    private func toolDetailView(_ detail: String) -> some View {
        let lang = toolLanguage
        let md = "```\(lang)\n\(detail)\n```"
        MarkdownView(md)
            .markdownFonts(baseSize: 10)
            .codeBlockStyle(.default(lightTheme: "github", darkTheme: "github-dark"))
    }

    @ViewBuilder
    private func editDiffView(oldStr: String, newStr: String) -> some View {
        UnifiedDiffView(oldText: oldStr, newText: newStr, searchText: searchText)
    }

    /// Determine the code fence language for syntax highlighting
    private var toolLanguage: String {
        switch message.toolName {
        case "Edit": return "diff"
        case "Bash": return "bash"
        case "Write":
            // Infer from file extension
            let ext = (message.text as NSString).pathExtension.lowercased()
            switch ext {
            case "swift": return "swift"
            case "ts", "tsx": return "typescript"
            case "js", "jsx": return "javascript"
            case "py": return "python"
            case "go": return "go"
            case "rs": return "rust"
            case "json": return "json"
            case "yml", "yaml": return "yaml"
            case "html": return "html"
            case "css": return "css"
            case "sql": return "sql"
            case "sh", "bash", "zsh": return "bash"
            case "md": return "markdown"
            default: return ""
            }
        case "Read":
            let ext = (message.text as NSString).pathExtension.lowercased()
            switch ext {
            case "swift": return "swift"
            case "ts", "tsx": return "typescript"
            case "js", "jsx": return "javascript"
            case "py": return "python"
            case "go": return "go"
            case "json": return "json"
            case "yml", "yaml": return "yaml"
            default: return ""
            }
        default: return ""
        }
    }
}
