import SwiftUI
import ClaudeStatisticsKit
import MarkdownView

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
