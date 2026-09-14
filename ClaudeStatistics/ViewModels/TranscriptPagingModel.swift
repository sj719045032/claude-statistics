import Foundation
import ClaudeStatisticsKit

/// Backs the transcript detail view with a bounded window instead of every
/// message. Providers adopting `PagedTranscriptProvider` stream an outline —
/// row identity plus the bytes each row came from — and the model materializes
/// only the pages around what is on screen. Providers that have not adopted it
/// keep one whole-file parse; the host bounds its concurrency, not its
/// allocation.
///
/// Search always runs off the main thread over the full history: FTS covers the
/// session list, and dropping transcript rows it does not index would make
/// in-transcript search lossy.
@MainActor
final class TranscriptPagingModel: ObservableObject {
    /// Rows materialized per request. Small enough that a scroll never
    /// materializes far more than a screenful, large enough to amortize the
    /// per-page reader setup.
    static let defaultPageSize = 40

    let pageSize: Int
    private let maxCachedPages: Int
    private let maxWindowBytes: Int

    init(pageSize: Int = TranscriptPagingModel.defaultPageSize,
         maxCachedPages: Int = 12, maxWindowBytes: Int = 8 * 1024 * 1024) {
        precondition(pageSize > 0 && maxCachedPages > 0 && maxWindowBytes > 0)
        self.pageSize = pageSize
        self.maxCachedPages = maxCachedPages
        self.maxWindowBytes = maxWindowBytes
    }

    struct SearchState: Equatable {
        var query = ""
        var matchedIds: [String] = []
        var isRunning = false
    }

    /// What a background batch has to work from. Sendable so the whole search
    /// runs off the main actor.
    private enum Source: Sendable {
        case none
        case paged(provider: any PagedTranscriptProvider, path: String,
                   sources: [String: TranscriptSourceCheckpoint])
        /// The provider has no paging capability: one full parse is retained.
        case whole([String: TranscriptDisplayMessage])
    }

    @Published private(set) var entries: [TranscriptOutlineEntry] = []
    /// `entries` after the role/tool filters. Recomputed when the outline or a
    /// filter changes — never from a view body, which re-runs on every scroll
    /// tick and every materialized page.
    @Published private(set) var visibleEntries: [TranscriptOutlineEntry] = []
    @Published private(set) var availableTools: [String] = []
    @Published private(set) var isLoadingOutline = true
    @Published private(set) var searchState = SearchState()
    /// Materialized rows for the pages currently retained, keyed by entry id.
    @Published private(set) var rows: [String: TranscriptDisplayMessage] = [:]
    @Published private(set) var roleFilters: Set<String> = []  // empty = show all
    @Published private(set) var toolFilters: Set<String> = []  // empty = show all tools

    private var source: Source = .none
    private var indexById: [String: Int] = [:]
    /// Most-recently-touched page indices; the tail is evicted first.
    private var residentPages: [Int] = []
    private var residentBytes = 0
    private var pageTasks: [Int: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?
    private var retainedFile: ArchivedTranscriptFile?

    var isPaged: Bool {
        if case .paged = source { return true }
        return false
    }

    // MARK: - Loading

    /// `provider` is nil for providers without the paging capability;
    /// `wholeParse` is then the compatibility fallback. `file` is an archived
    /// transcript's temporary file, kept on disk while this model reads it.
    func load(path: String, provider: (any PagedTranscriptProvider)?, retaining file: ArchivedTranscriptFile? = nil,
              wholeParse: () async -> [TranscriptDisplayMessage]) async {
        retainedFile = file
        isLoadingOutline = true
        if let provider, let outline = await loadOutline(provider: provider, path: path) {
            source = .paged(provider: provider, path: path, sources: outline.sources)
            apply(entries: outline.entries)
            isLoadingOutline = false
            return
        }

        let messages = await wholeParse()
        let byId = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        source = .whole(byId)
        apply(entries: messages.map {
            TranscriptOutlineEntry(
                id: $0.id, role: $0.role, toolName: $0.toolName, timestamp: $0.timestamp,
                locator: TranscriptRecordLocator(source: path, ranges: [])
            )
        })
        rows = byId
        isLoadingOutline = false
    }

    func cancelAll() {
        searchTask?.cancel()
        searchTask = nil
        for task in pageTasks.values { task.cancel() }
        pageTasks = [:]
    }

    private func loadOutline(provider: any PagedTranscriptProvider,
                             path: String) async -> TranscriptOutline? {
        let bytes = (try? TranscriptFileSnapshot.read(at: path).size) ?? 1
        return try? await BackgroundWorkScheduler.shared.run(
            estimatedBytes: max(1, bytes), priority: .interactive
        ) {
            try provider.loadTranscriptOutline(at: path)
        }
    }

    private func apply(entries: [TranscriptOutlineEntry]) {
        self.entries = entries
        availableTools = Array(Set(entries.compactMap(\.toolName))).sorted()
        indexById = Dictionary(
            entries.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        refreshVisible()
    }

    // MARK: - Filters

    func toggleRole(_ role: String) {
        if roleFilters.contains(role) {
            roleFilters.remove(role)
            if role == "tool" { toolFilters = [] }
        } else {
            roleFilters.insert(role)
        }
        refreshVisible()
    }

    func toggleTool(_ tool: String) {
        if toolFilters.contains(tool) { toolFilters.remove(tool) } else { toolFilters.insert(tool) }
        refreshVisible()
    }

    func clearFilters() {
        guard !roleFilters.isEmpty || !toolFilters.isEmpty else { return }
        roleFilters = []
        toolFilters = []
        refreshVisible()
    }

    private func refreshVisible() {
        visibleEntries = entries.filter {
            Self.passesFilters($0, roleFilters: roleFilters, toolFilters: toolFilters)
        }
    }

    // MARK: - Windowing

    func row(id: String) -> TranscriptDisplayMessage? { rows[id] }

    /// Called when a row scrolls into view; materializes the page holding it.
    func requestRow(id: String) {
        guard case .paged = source, rows[id] == nil, let index = indexById[id] else { return }
        materialize(page: index / pageSize)
    }

    private func materialize(page: Int) {
        guard case .paged(let provider, let path, let sources) = source,
              pageTasks[page] == nil else { return }
        let slice = entries(inPage: page)
        guard !slice.isEmpty, slice.contains(where: { rows[$0.id] == nil }) else { return }

        pageTasks[page] = Task { [weak self] in
            let bytes = slice.reduce(0) { $0 + $1.locator.byteCount }
            let loaded = try? await BackgroundWorkScheduler.shared.run(
                estimatedBytes: max(1, bytes), priority: .interactive
            ) {
                let rows = try provider.loadTranscriptPage(at: path, entries: slice)
                // A replaced source keeps these offsets in range, so a page
                // read from it would be plausible and wrong.
                guard TranscriptOutline.sourcesMatch(sources) else {
                    throw TranscriptFileReader.ReadError.changedDuringRead
                }
                return rows
            }
            guard let self, !Task.isCancelled else { return }
            if loaded == nil, !TranscriptOutline.sourcesMatch(sources) {
                self.reloadOutline()
                return
            }
            self.finishPage(page, loaded: loaded)
        }
    }

    private func finishPage(_ page: Int, loaded: [TranscriptDisplayMessage]?) {
        pageTasks[page] = nil
        guard let loaded, !loaded.isEmpty else { return }
        for message in loaded { rows[message.id] = message }
        residentBytes += loaded.reduce(0) { $0 + Self.estimatedBytes(of: $1) }
        touch(page: page)
        evictIfNeeded()
    }

    /// The transcript was replaced while it was open: rebuild the outline
    /// once and drop every row read from the old one.
    private func reloadOutline() {
        guard case .paged(let provider, let path, _) = source, !isLoadingOutline else { return }
        isLoadingOutline = true
        for task in pageTasks.values { task.cancel() }
        pageTasks = [:]
        rows = [:]
        residentPages = []
        residentBytes = 0
        Task { [weak self] in
            let outline = await self?.loadOutline(provider: provider, path: path)
            guard let self else { return }
            if let outline {
                self.source = .paged(provider: provider, path: path, sources: outline.sources)
                self.apply(entries: outline.entries)
            }
            self.isLoadingOutline = false
        }
    }

    private func entries(inPage page: Int) -> [TranscriptOutlineEntry] {
        let start = page * pageSize
        guard start >= 0, start < entries.count else { return [] }
        return Array(entries[start..<min(start + pageSize, entries.count)])
    }

    private func touch(page: Int) {
        residentPages.removeAll { $0 == page }
        residentPages.insert(page, at: 0)
    }

    private func evictIfNeeded() {
        while residentPages.count > 1,
              residentPages.count > maxCachedPages || residentBytes > maxWindowBytes {
            guard let victim = residentPages.popLast() else { return }
            pageTasks[victim]?.cancel()
            pageTasks[victim] = nil
            for entry in entries(inPage: victim) {
                guard let message = rows.removeValue(forKey: entry.id) else { continue }
                residentBytes -= Self.estimatedBytes(of: message)
            }
        }
        residentBytes = max(0, residentBytes)
    }

    private static func estimatedBytes(of message: TranscriptDisplayMessage) -> Int {
        message.text.utf8.count
            + (message.toolDetail?.utf8.count ?? 0)
            + (message.editOldString?.utf8.count ?? 0)
            + (message.editNewString?.utf8.count ?? 0)
            + 128
    }

    // MARK: - Full-history search

    /// Runs the query over every row that passes the filters, in bounded
    /// batches, off the main thread. A new query cancels the previous run.
    /// `snippetContext` is the FTS snippet the session list came from; when
    /// given, the model reports which match best corresponds to it.
    func search(query: String, snippetContext: String? = nil,
                onFinish: @escaping @MainActor ([String], String?) -> Void = { _, _ in }) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchState = SearchState()
            onFinish([], nil)
            return
        }

        let candidates = visibleEntries
        let source = self.source
        let phrase = snippetContext?.lowercased()
        let batchSize = pageSize
        searchState = SearchState(query: trimmed, matchedIds: [], isRunning: true)

        searchTask = Task { [weak self] in
            var matched: [String] = []
            var snippetMatch: String?

            for start in stride(from: 0, to: candidates.count, by: batchSize) {
                if Task.isCancelled { return }
                let batch = Array(candidates[start..<min(start + batchSize, candidates.count)])
                let hits = (try? await BackgroundWorkScheduler.shared.run(
                    estimatedBytes: max(1, batch.reduce(0) { $0 + $1.locator.byteCount }),
                    priority: .interactive
                ) {
                    Self.matches(in: batch, source: source, query: trimmed, phrase: phrase)
                }) ?? Batch()

                matched.append(contentsOf: hits.matchedIds)
                if snippetMatch == nil { snippetMatch = hits.snippetId }
                let progress = matched
                await MainActor.run { [weak self] in
                    guard let self, self.searchState.query == trimmed else { return }
                    self.searchState.matchedIds = progress
                }
            }

            if Task.isCancelled { return }
            let final = matched
            let located = snippetMatch
            await MainActor.run { [weak self] in
                guard let self, self.searchState.query == trimmed else { return }
                self.searchState = SearchState(query: trimmed, matchedIds: final, isRunning: false)
                onFinish(final, located)
            }
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchState = SearchState()
    }

    private struct Batch: Sendable {
        var matchedIds: [String] = []
        var snippetId: String?
    }

    /// Materialize a batch, test it, and throw the rows away. Runs off the main
    /// actor, so a full-history scan never stalls rendering and never grows the
    /// resident window.
    private nonisolated static func matches(in batch: [TranscriptOutlineEntry], source: Source,
                                            query: String, phrase: String?) -> Batch {
        var messages: [TranscriptDisplayMessage] = []
        switch source {
        case .none:
            return Batch()
        case .whole(let byId):
            messages = batch.compactMap { byId[$0.id] }
        case .paged(let provider, let path, let sources):
            guard let loaded = try? provider.loadTranscriptPage(at: path, entries: batch),
                  TranscriptOutline.sourcesMatch(sources) else {
                return Batch()
            }
            messages = loaded
        }

        var result = Batch()
        for message in messages {
            let text = SearchUtils.transcriptSearchableText(for: message)
            guard SearchUtils.textMatches(query: query, in: text) else { continue }
            result.matchedIds.append(message.id)
            if let phrase, result.snippetId == nil, text.lowercased().contains(phrase) {
                result.snippetId = message.id
            }
        }
        return result
    }

    private static func passesFilters(_ entry: TranscriptOutlineEntry,
                              roleFilters: Set<String>, toolFilters: Set<String>) -> Bool {
        if !roleFilters.isEmpty && !roleFilters.contains(entry.role) { return false }
        if !toolFilters.isEmpty && entry.role == "tool" && !toolFilters.contains(entry.toolName ?? "") {
            return false
        }
        return true
    }
}
