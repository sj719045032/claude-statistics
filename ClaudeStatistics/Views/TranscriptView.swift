import SwiftUI
import ClaudeStatisticsKit
import MarkdownView

struct TranscriptView: View {
    let session: Session
    let initialSearchQuery: String?
    let initialSnippetContext: String?
    let onBack: () -> Void
    @ObservedObject var viewModel: SessionViewModel

    /// Row identity and byte locators for the whole transcript; message bodies
    /// are materialized a page at a time.
    @StateObject private var pager = TranscriptPagingModel()
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var currentMatchIndex = 0
    @State private var scrollPosition: String?
    @State private var searchDebounce: Task<Void, Never>?
    /// `true` when the visible anchor is within the last few messages —
    /// flips the floating jump button from "go to bottom" to "go to top".
    @State private var atBottom: Bool = false
    @State private var scrollButtonHovered: Bool = false

    private var matchedIds: [String] { pager.searchState.matchedIds }

    private var roleOptions: [(key: String, label: String, icon: String)] {
        [
            ("user", "User", "person.circle.fill"),
            ("assistant", viewModel.providerDisplayName, "brain"),
            ("tool", "Tools", "wrench.and.screwdriver"),
        ]
    }

    private var filteredEntries: [TranscriptOutlineEntry] { pager.visibleEntries }

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

                Text("transcript.title \(filteredEntries.count)")
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
                    if pager.searchState.isRunning && matchedIds.isEmpty {
                        ProgressView().controlSize(.mini)
                    } else if !matchedIds.isEmpty {
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
                    let isActive = pager.roleFilters.contains(option.key)
                    Button {
                        pager.toggleRole(option.key)
                        debounceSearch()
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

                if pager.roleFilters.contains("tool") && !pager.availableTools.isEmpty {
                    Divider().frame(height: 14)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 3) {
                            ForEach(pager.availableTools, id: \.self) { tool in
                                let isActive = pager.toolFilters.contains(tool)
                                Button {
                                    pager.toggleTool(tool)
                                    debounceSearch()
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

                if !pager.roleFilters.isEmpty || !pager.toolFilters.isEmpty {
                    Button {
                        pager.clearFilters()
                        debounceSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Text("\(filteredEntries.count)")
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
                        ForEach(filteredEntries) { entry in
                            row(for: entry)
                                .id(entry.id)
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
                    if filteredEntries.count > 1 {
                        Button {
                            let targetId: String? = atBottom ? filteredEntries.first?.id : filteredEntries.last?.id
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
                    let entries = filteredEntries
                    let endZone = max(0, entries.count - 5)
                    guard let idx = entries.firstIndex(where: { $0.id == newId }) else { return }
                    let nowAtBottom = idx >= endZone
                    if nowAtBottom != atBottom {
                        withAnimation(Theme.quickSpring) { atBottom = nowAtBottom }
                    }
                }
            }
        }
        .task {
            if session.isArchived {
                // Written to a temporary file, so the session's own provider
                // pages it like any transcript.
                let file = await viewModel.archivedTranscriptFile(for: session)
                await pager.load(
                    path: file?.path ?? session.filePath,
                    provider: file == nil ? nil : viewModel.pagedTranscriptProvider,
                    retaining: file,
                    wholeParse: { await viewModel.loadMessages(in: file) }
                )
            } else {
                await pager.load(
                    path: session.filePath,
                    provider: viewModel.pagedTranscriptProvider,
                    wholeParse: { await viewModel.loadMessages(at: session.filePath) }
                )
            }

            // Set up search text
            if viewModel.transcriptInitialLoadDone {
                searchText = viewModel.transcriptSearchText
            } else if let query = initialSearchQuery, !query.isEmpty {
                searchText = query
            }

            let restoringIndex = viewModel.transcriptInitialLoadDone
            let snippet = restoringIndex ? nil : initialSnippetContext
            viewModel.transcriptInitialLoadDone = true
            isLoading = false

            guard !searchText.isEmpty else { return }
            // The first search owns the scroll target: with paging the matches
            // are not known until the background scan reports them.
            runSearch(snippetContext: snippet) { matches, snippetMatch in
                if restoringIndex {
                    currentMatchIndex = min(viewModel.transcriptMatchIndex, max(matches.count - 1, 0))
                } else if let snippetMatch, let index = matches.firstIndex(of: snippetMatch) {
                    currentMatchIndex = index
                } else {
                    currentMatchIndex = 0
                }
                guard matches.indices.contains(currentMatchIndex) else { return }
                scrollPosition = matches[currentMatchIndex]
            }
        }
        .onDisappear {
            // Save state to ViewModel so it survives popover cycles
            viewModel.transcriptSearchText = searchText
            viewModel.transcriptMatchIndex = currentMatchIndex
            searchDebounce?.cancel()
            pager.cancelAll()
        }
        .onChange(of: searchText) { _, _ in
            debounceSearch()
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for entry: TranscriptOutlineEntry) -> some View {
        if let msg = pager.row(id: entry.id) {
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
        } else {
            TranscriptRowPlaceholder(role: entry.role)
                .task { pager.requestRow(id: entry.id) }
        }
    }

    // MARK: - Logic

    private func isCurrentMatch(_ id: String) -> Bool {
        matchedIds.indices.contains(currentMatchIndex) && matchedIds[currentMatchIndex] == id
    }

    /// Search runs off the main thread over the full history, so a keystroke
    /// must not start a scan the next keystroke invalidates.
    private func debounceSearch() {
        searchDebounce?.cancel()
        let text = searchText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            pager.cancelSearch()
            currentMatchIndex = 0
            return
        }
        searchDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, searchText == text else { return }
            runSearch { matches, _ in
                currentMatchIndex = 0
                if let first = matches.first { scrollPosition = first }
            }
        }
    }

    private func runSearch(snippetContext: String? = nil,
                           onFinish: @escaping @MainActor ([String], String?) -> Void) {
        pager.search(
            query: searchText,
            snippetContext: snippetContext.flatMap(Self.extractSnippetContext),
            onFinish: onFinish
        )
    }

    /// Extract a short phrase around the best «» highlight pair in an FTS snippet.
    /// Checks all pairs and picks the one with the most surrounding context.
    static func extractSnippetContext(_ snippet: String) -> String? {
        guard !snippet.isEmpty else { return nil }
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
            let cleaned = firstSeg.replacingOccurrences(of: "«", with: "")
                .replacingOccurrences(of: "»", with: "").trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? nil : cleaned
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
            let afterClean = afterSeg.replacingOccurrences(of: "«", with: "")
                .replacingOccurrences(of: "»", with: "")
                .trimmingCharacters(in: .whitespaces)
            let afterContext = afterClean.count > 30 ? String(afterClean.prefix(30)) : afterClean

            let candidate = (beforeContext + highlightedWord + afterContext).trimmingCharacters(in: .whitespaces)
            if candidate.count > bestContext.count {
                bestContext = candidate
            }
        }

        return bestContext.isEmpty ? nil : bestContext
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

/// Stand-in for a row whose body has not been read yet. Keeps the list's
/// geometry stable while a page is materialized.
private struct TranscriptRowPlaceholder: View {
    let role: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray.opacity(0.12))
                .frame(width: role == "tool" ? 90 : 160, height: 9)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray.opacity(0.08))
                .frame(maxWidth: .infinity)
                .frame(height: 9)
        }
        .padding(.horizontal, 12)
        .frame(height: role == "tool" ? 26 : 38, alignment: .center)
    }
}
