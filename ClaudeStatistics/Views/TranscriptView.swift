import SwiftUI
import ClaudeStatisticsKit
import MarkdownView

// MARK: - Scaled MarkdownView fonts

private extension View {
    func markdownFonts(baseSize: CGFloat = 11) -> some View {
        self.font(.system(size: baseSize), for: .body)
            .font(.system(size: baseSize - 1, design: .monospaced), for: .codeBlock)
            .font(.system(size: baseSize + 5, weight: .bold), for: .h1)
            .font(.system(size: baseSize + 4, weight: .bold), for: .h2)
            .font(.system(size: baseSize + 3, weight: .semibold), for: .h3)
            .font(.system(size: baseSize + 2, weight: .semibold), for: .h4)
            .font(.system(size: baseSize + 1, weight: .medium), for: .h5)
            .font(.system(size: baseSize, weight: .medium), for: .h6)
            .font(.system(size: baseSize, design: .serif), for: .blockQuote)
            .font(.system(size: baseSize - 1), for: .tableBody)
            .font(.system(size: baseSize - 1, weight: .semibold), for: .tableHeader)
    }
}

// MARK: - Unified diff (shared by transcript Edit rows and notch permission card)

struct UnifiedDiffLine {
    let tag: Character  // " ", "-", "+", "."
    let text: String

    static func compute(old: String, new: String, contextLines: Int = 3) -> [UnifiedDiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)

        var removedAt = Set<Int>()
        var insertedAt: [Int: [String]] = [:]

        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removedAt.insert(offset)
            case .insert(let offset, let element, _):
                insertedAt[offset, default: []].append(element)
            }
        }

        var result: [UnifiedDiffLine] = []
        var newIdx = 0

        for oldIdx in 0..<oldLines.count {
            if removedAt.contains(oldIdx) {
                result.append(UnifiedDiffLine(tag: "-", text: oldLines[oldIdx]))
            } else {
                if let inserts = insertedAt[newIdx] {
                    for line in inserts { result.append(UnifiedDiffLine(tag: "+", text: line)) }
                    insertedAt.removeValue(forKey: newIdx)
                    newIdx += inserts.count
                }
                result.append(UnifiedDiffLine(tag: " ", text: oldLines[oldIdx]))
                newIdx += 1
            }
        }

        for idx in insertedAt.keys.sorted() {
            for line in insertedAt[idx]! {
                result.append(UnifiedDiffLine(tag: "+", text: line))
            }
        }

        // Keep changed lines + their context window; collapse the rest into "..."
        var showLine = [Bool](repeating: false, count: result.count)
        for (i, line) in result.enumerated() where line.tag != " " {
            let start = max(0, i - contextLines)
            let end = min(result.count - 1, i + contextLines)
            for j in start...end { showLine[j] = true }
        }

        var output: [UnifiedDiffLine] = []
        var inGap = false
        for (i, line) in result.enumerated() {
            if showLine[i] {
                inGap = false
                output.append(line)
            } else if !inGap {
                inGap = true
                if !output.isEmpty { output.append(UnifiedDiffLine(tag: ".", text: "...")) }
            }
        }

        return output
    }
}

struct UnifiedDiffView: View {
    let oldText: String
    let newText: String
    var searchText: String = ""
    var contextLines: Int = 3

    var body: some View {
        let lines = UnifiedDiffLine.compute(old: oldText, new: newText, contextLines: contextLines)
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let baseColor: Color = line.tag == "-" ? Color(red: 1.0, green: 0.86, blue: 0.84) :
                        line.tag == "+" ? Color(red: 0.67, green: 0.96, blue: 0.70) :
                        .primary.opacity(0.6)
                    let q = searchText.trimmingCharacters(in: .whitespaces)

                    HStack(spacing: 0) {
                        Text(String(line.tag))
                            .frame(width: 14)
                        if !q.isEmpty && SearchUtils.textMatches(query: q, in: line.text) {
                            SearchUtils.highlightedText(line.text, query: q, baseColor: baseColor)
                        } else {
                            Text(line.text)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(baseColor)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                    .padding(.trailing, 8)
                    .background(line.tag == "-" ? Color(red: 0.40, green: 0.02, blue: 0.05) :
                                line.tag == "+" ? Color(red: 0.01, green: 0.23, blue: 0.09) :
                                Color.clear)
                }
            }
        }
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }
}

struct TranscriptView: View {
    let session: Session
    let initialSearchQuery: String?
    let initialSnippetContext: String?
    let onBack: () -> Void
    @ObservedObject var viewModel: SessionViewModel

    @State private var messages: [TranscriptDisplayMessage] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var matchedIds: [String] = []
    @State private var currentMatchIndex = 0
    @State private var scrollPosition: String?
    @State private var roleFilters: Set<String> = []  // empty = show all
    @State private var toolFilters: Set<String> = []  // empty = show all tools
    /// `true` when the visible anchor is within the last few messages —
    /// flips the floating jump button from "go to bottom" to "go to top".
    @State private var atBottom: Bool = false
    @State private var scrollButtonHovered: Bool = false

    private var roleOptions: [(key: String, label: String, icon: String)] {
        [
            ("user", "User", "person.circle.fill"),
            ("assistant", viewModel.providerDisplayName, "brain"),
            ("tool", "Tools", "wrench.and.screwdriver"),
        ]
    }

    private var availableTools: [String] {
        Array(Set(messages.compactMap(\.toolName))).sorted()
    }

    private var filteredMessages: [TranscriptDisplayMessage] {
        messages.filter { msg in
            if !roleFilters.isEmpty && !roleFilters.contains(msg.role) { return false }
            if !toolFilters.isEmpty && msg.role == "tool" && !toolFilters.contains(msg.toolName ?? "") { return false }
            return true
        }
    }

    private var sessionTitle: String? {
        let qs = viewModel.quickStat(for: session)
        return qs?.topic ?? qs?.sessionName
    }

    var body: some View {
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

                if let title = sessionTitle {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Spacer()
                }

                Text("transcript.title \(filteredMessages.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("transcript.search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { jumpToNext() }

                if !searchText.isEmpty {
                    if !matchedIds.isEmpty {
                        Text("\(currentMatchIndex + 1)/\(matchedIds.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Button(action: jumpToPrev) {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.hoverScale)

                        Button(action: jumpToNext) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.hoverScale)
                    } else {
                        Text("transcript.noMatch")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.hoverScale)
                }
            }
            .padding(8)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(6)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            // Filter bar
            HStack(spacing: 4) {
                ForEach(roleOptions, id: \.key) { option in
                    let isActive = roleFilters.contains(option.key)
                    Button {
                        if isActive {
                            roleFilters.remove(option.key)
                            if option.key == "tool" { toolFilters = [] }
                        } else {
                            roleFilters.insert(option.key)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: option.icon).font(.system(size: 9))
                            Text(option.label).font(.system(size: 10))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(isActive ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1))
                        .foregroundStyle(isActive ? .blue : .secondary)
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                if roleFilters.contains("tool") && !availableTools.isEmpty {
                    Divider().frame(height: 14)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(availableTools, id: \.self) { tool in
                                let isActive = toolFilters.contains(tool)
                                Button {
                                    if isActive { toolFilters.remove(tool) } else { toolFilters.insert(tool) }
                                } label: {
                                    Text(tool)
                                        .font(.system(size: 9, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(isActive ? Color.orange.opacity(0.2) : Color.gray.opacity(0.08))
                                        .foregroundStyle(isActive ? .orange : .secondary)
                                        .cornerRadius(3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Spacer()

                if !roleFilters.isEmpty || !toolFilters.isEmpty {
                    Button {
                        roleFilters = []
                        toolFilters = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text("\(filteredMessages.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            Divider()

            // Messages — LazyVStack always present, loading as overlay
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredMessages) { msg in
                            Group {
                                if msg.role == "tool" {
                                    ToolCallRow(message: msg, searchText: searchText,
                                                isCurrentMatch: isCurrentMatch(msg.id),
                                                providerDisplayName: viewModel.providerDisplayName,
                                                sessionFilePath: session.filePath,
                                                loadMessagesAtPath: viewModel.loadMessages(at:))
                                } else {
                                    MessageRow(message: msg, searchText: searchText,
                                               isCurrentMatch: isCurrentMatch(msg.id),
                                               assistantName: viewModel.providerDisplayName)
                                }
                            }
                            .id(msg.id)
                        }
                    }
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
                }
                .overlay {
                    if isLoading {
                        VStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("transcript.loading")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if filteredMessages.count > 1 {
                        Button {
                            let targetId: String? = atBottom ? filteredMessages.first?.id : filteredMessages.last?.id
                            let anchor: UnitPoint = atBottom ? .top : .bottom
                            guard let id = targetId else { return }
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(id, anchor: anchor)
                            }
                            scrollPosition = id
                        } label: {
                            Image(systemName: atBottom ? "arrow.up" : "arrow.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle()
                                        .fill(Color.blue.opacity(scrollButtonHovered ? 1.0 : 0.85))
                                )
                                .scaleEffect(scrollButtonHovered ? 1.08 : 1.0)
                                .shadow(
                                    color: .black.opacity(scrollButtonHovered ? 0.28 : 0.2),
                                    radius: scrollButtonHovered ? 5 : 3,
                                    y: 1
                                )
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .help(atBottom ? "transcript.scrollToTop" : "transcript.scrollToBottom")
                        .onHover { hovering in
                            withAnimation(Theme.quickSpring) {
                                scrollButtonHovered = hovering
                            }
                        }
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                    }
                }
                .scrollPosition(id: $scrollPosition, anchor: .top)
                .onChange(of: scrollPosition) { _, newId in
                    guard let newId else { return }
                    let endZone = max(0, filteredMessages.count - 5)
                    guard let idx = filteredMessages.firstIndex(where: { $0.id == newId }) else { return }
                    let nowAtBottom = idx >= endZone
                    if nowAtBottom != atBottom {
                        withAnimation(Theme.quickSpring) { atBottom = nowAtBottom }
                    }
                }
            }
        }
        .task {
            await loadMessages()

            // Set up search text
            if viewModel.transcriptInitialLoadDone {
                searchText = viewModel.transcriptSearchText
            } else if let query = initialSearchQuery, !query.isEmpty {
                searchText = query
            }

            // Compute matches
            if !searchText.isEmpty {
                updateMatches(query: searchText, autoScroll: false)
            }

            // Determine target
            var targetId: String?
            if viewModel.transcriptInitialLoadDone {
                currentMatchIndex = min(viewModel.transcriptMatchIndex, max(matchedIds.count - 1, 0))
                if matchedIds.indices.contains(currentMatchIndex) {
                    targetId = matchedIds[currentMatchIndex]
                }
            } else {
                viewModel.transcriptInitialLoadDone = true
                if initialSnippetContext != nil {
                    locateSnippetMatch()
                    // locateSnippetMatch sets scrollPosition directly, capture it
                    targetId = scrollPosition
                } else if let first = matchedIds.first {
                    targetId = first
                }
            }

            isLoading = false

            // Schedule scroll for NEXT update cycle — messages must be rendered first
            if let targetId {
                Task { @MainActor in
                    scrollPosition = targetId
                }
            }
        }
        .onDisappear {
            // Save state to ViewModel so it survives popover cycles
            viewModel.transcriptSearchText = searchText
            viewModel.transcriptMatchIndex = currentMatchIndex
        }
        .onChange(of: searchText) { _, newValue in
            updateMatches(query: newValue)
        }
        .onChange(of: roleFilters) { _, _ in
            updateMatches(query: searchText)
        }
        .onChange(of: toolFilters) { _, _ in
            updateMatches(query: searchText)
        }
    }

    // MARK: - Logic

    private func isCurrentMatch(_ id: String) -> Bool {
        matchedIds.indices.contains(currentMatchIndex) && matchedIds[currentMatchIndex] == id
    }

    private func loadMessages() async {
        messages = await viewModel.loadMessages(for: session)
        // NOTE: isLoading is set in .task AFTER scroll target is determined
    }

    private func updateMatches(query: String, autoScroll: Bool = true) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            matchedIds = []
            currentMatchIndex = 0
            return
        }

        matchedIds = filteredMessages.filter { msg in
            let allFields = [
                SearchUtils.stripMarkdown(msg.text),
                msg.text,
                msg.toolName ?? "",
                msg.toolDetail ?? "",
                msg.editOldString ?? "",
                msg.editNewString ?? ""
            ].joined(separator: " ")
            return SearchUtils.textMatches(query: trimmed, in: allFields)
        }.map(\.id)
        currentMatchIndex = 0
        if autoScroll, let first = matchedIds.first {
            scrollPosition = first
        }
    }

    /// Find the match that best corresponds to the FTS snippet from session list
    private func locateSnippetMatch() {
        guard let snippet = initialSnippetContext, !snippet.isEmpty, !matchedIds.isEmpty else { return }

        // Extract a short context phrase around the first «highlighted» term
        // e.g. "问题是从列表 «snippet» 跳过去后" → "问题是从列表 snippet 跳过去后"
        let contextPhrase = extractSnippetContext(snippet)
        guard !contextPhrase.isEmpty else { return }

        let phraseLower = contextPhrase.lowercased()
        let msgLookup = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

        for (i, matchId) in matchedIds.enumerated() {
            if let msg = msgLookup[matchId] {
                // Search in all text fields — must match what updateMatches checks
                let allText = [
                    SearchUtils.stripMarkdown(msg.text),
                    msg.text,
                    msg.toolName ?? "",
                    msg.toolDetail ?? "",
                    msg.editOldString ?? "",
                    msg.editNewString ?? ""
                ].joined(separator: " ").lowercased()
                if allText.contains(phraseLower) {
                    currentMatchIndex = i
                    scrollPosition = matchId
                    return
                }
            }
        }
    }

    /// Extract a short phrase around the best «» highlight pair in an FTS snippet.
    /// Checks all pairs and picks the one with the most surrounding context.
    private func extractSnippetContext(_ snippet: String) -> String {
        // Collect all «» pairs
        var pairs: [(open: Range<String.Index>, close: Range<String.Index>)] = []
        var searchFrom = snippet.startIndex
        while let openRange = snippet.range(of: "«", range: searchFrom..<snippet.endIndex),
              let closeRange = snippet.range(of: "»", range: openRange.upperBound..<snippet.endIndex) {
            pairs.append((open: openRange, close: closeRange))
            searchFrom = closeRange.upperBound
        }

        guard !pairs.isEmpty else {
            // No markers, use first segment before …
            let firstSeg = snippet.components(separatedBy: "…").first ?? snippet
            return firstSeg.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "").trimmingCharacters(in: .whitespaces)
        }

        // Build context for each pair, pick the longest (most surrounding context)
        var bestContext = ""
        for pair in pairs {
            let highlightedWord = String(snippet[pair.open.upperBound..<pair.close.lowerBound])

            // Take context before «
            let beforeAll = String(snippet[snippet.startIndex..<pair.open.lowerBound])
            let beforeClean = beforeAll.replacingOccurrences(of: "…", with: "")
                .replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
                .trimmingCharacters(in: .whitespaces)
            let beforeContext = beforeClean.count > 30 ? String(beforeClean.suffix(30)) : beforeClean

            // Take context after »
            let afterAll = String(snippet[pair.close.upperBound...])
            let afterSeg = afterAll.components(separatedBy: "…").first ?? afterAll
            let afterClean = afterSeg.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
                .trimmingCharacters(in: .whitespaces)
            let afterContext = afterClean.count > 30 ? String(afterClean.prefix(30)) : afterClean

            let candidate = (beforeContext + highlightedWord + afterContext).trimmingCharacters(in: .whitespaces)
            if candidate.count > bestContext.count {
                bestContext = candidate
            }
        }

        return bestContext
    }

    private func jumpToNext() {
        guard !matchedIds.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matchedIds.count
        scrollPosition = matchedIds[currentMatchIndex]
    }

    private func jumpToPrev() {
        guard !matchedIds.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matchedIds.count) % matchedIds.count
        scrollPosition = matchedIds[currentMatchIndex]
    }
}

// MARK: - MessageRow (user / assistant)

private struct MessageRow: View {
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

// MARK: - ToolCallRow

private struct ToolCallRow: View {
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

// MARK: - InlineImageView

private struct InlineImageView: View {
    let path: String
    private static let maxWidth: CGFloat = 350
    private static let maxHeight: CGFloat = 250

    var body: some View {
        if let nsImage = NSImage(contentsOfFile: path) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: Self.maxWidth, maxHeight: Self.maxHeight)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .onTapGesture {
                    ImageWindowController.show(nsImage: nsImage, path: path)
                }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Image Window Controller

private final class ImageWindowController {
    static func show(nsImage: NSImage, path: String) {
        let screenSize = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        let maxW = min(nsImage.size.width, screenSize.width * 0.85)
        let maxH = min(nsImage.size.height, screenSize.height * 0.85)
        let ratio = nsImage.size.width / nsImage.size.height
        let winW = min(maxW, maxH * ratio)
        let winH = winW / ratio + 36  // +36 for title bar

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(winW, 400), height: max(winH, 300)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(Int(nsImage.size.width))×\(Int(nsImage.size.height)) — \((path as NSString).lastPathComponent)"
        window.center()
        window.isReleasedWhenClosed = false

        let imageView = NSImageView(image: nsImage)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        window.contentView = imageView

        window.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
