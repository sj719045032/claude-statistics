import Foundation
import ClaudeStatisticsKit
import SwiftUI
import Combine

struct ProjectGroup: Identifiable {
    var id: String { projectPath }
    let projectPath: String
    let sessions: [Session]
    let resolvedPath: String
    var totalCost: Double = 0
    var totalTokens: Int = 0
    var totalMessages: Int = 0
    var toolUseCount: Int = 0

    var displayName: String {
        let path = resolvedPath
        return (path as NSString).lastPathComponent
    }

    var shortPath: String {
        let home = NSHomeDirectory()
        let path = resolvedPath
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var cwdPath: String {
        resolvedPath
    }
}

@MainActor
final class SessionViewModel: ObservableObject {
    let store: SessionDataStore

    @Published var selectedSession: Session?
    @Published var selectedSessionStats: SessionStats?
    @Published var isLoadingStats = false
    @Published var searchText = ""
    @Published var isSelecting = false
    @Published var selectedIds: Set<String> = []
    @Published var collapsedProjects: Set<String> = []

    /// Transcript view state
    @Published var showTranscript = false
    @Published var transcriptSearchQuery: String?
    @Published var transcriptSnippetContext: String?
    @Published var transcriptSearchText: String = ""
    @Published var transcriptMatchIndex: Int = 0
    @Published var transcriptInitialLoadDone = false
    private var transcriptEnteredFromList = false

    /// Snippets from FTS content search, keyed by session ID
    @Published var searchSnippets: [String: String] = [:]

    /// Monotonic generation token for the FTS search task. Bumped on
    /// every keystroke that triggers a new query; in-flight tasks check
    /// the value before writing back so a slow earlier query can't
    /// overwrite a faster later one.
    private var searchGeneration: UInt64 = 0

    /// Cached computed results — only recalculated when inputs change
    @Published private(set) var recentSessions: [Session] = []
    @Published private(set) var filteredSessions: [Session] = []
    @Published private(set) var projectGroups: [ProjectGroup] = []

    private var cancellables = Set<AnyCancellable>()

    var providerKind: ProviderKind { store.provider.kind }
    var providerDisplayName: String { store.provider.displayName }
    var providerCapabilities: ProviderCapabilities { store.provider.capabilities }

    init(store: SessionDataStore) {
        self.store = store

        // Debounced FTS content search — runs off-main, gated by a
        // generation token so a slow earlier query can't clobber a
        // faster later one.
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                guard text.count >= 2 else {
                    self.searchGeneration &+= 1
                    if !self.searchSnippets.isEmpty {
                        self.searchSnippets = [:]
                    }
                    return
                }
                self.searchGeneration &+= 1
                let generation = self.searchGeneration
                let store = self.store
                Task { @MainActor [weak self] in
                    let results = await store.searchMessages(query: text)
                    guard let self, self.searchGeneration == generation else { return }
                    self.searchSnippets = Dictionary(
                        results.map { ($0.sessionId, $0.snippet) },
                        uniquingKeysWith: { first, _ in first }
                    )
                }
            }
            .store(in: &cancellables)

        // Recompute groups when sessions, search, or snippets change
        store.$sessions
            .combineLatest($searchText, $searchSnippets)
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeGroups() }
            .store(in: &cancellables)

        // Initial computation
        recomputeGroups()
    }

    private func recomputeGroups() {
        // filteredSessions
        let filtered: [Session]
        if searchText.isEmpty {
            filtered = store.sessions
        } else {
            var matchedIds = Set<String>()
            var result: [Session] = []
            for session in store.sessions {
                if SearchUtils.textMatches(query: searchText, in: session.displayName) ||
                    SearchUtils.textMatches(query: searchText, in: session.externalID) ||
                    SearchUtils.textMatches(query: searchText, in: store.quickStats[session.id]?.topic ?? "") ||
                    SearchUtils.textMatches(query: searchText, in: store.quickStats[session.id]?.sessionName ?? "")
                {
                    result.append(session)
                    matchedIds.insert(session.id)
                }
            }
            if !searchSnippets.isEmpty {
                let sessionLookup = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, $0) })
                for sessionId in searchSnippets.keys {
                    if !matchedIds.contains(sessionId), let session = sessionLookup[sessionId] {
                        result.append(session)
                        matchedIds.insert(sessionId)
                    }
                }
            }
            filtered = result
        }
        filteredSessions = filtered
        recentSessions = searchText.isEmpty ? Array(store.sessions.prefix(3)) : []

        // projectGroups (with pre-computed cost)
        let statsMap = store.parsedStats
        let provider = store.provider
        let grouped = Dictionary(grouping: filtered) { $0.cwd ?? $0.projectPath }
        projectGroups = grouped.map { key, sessions in
            let sorted = sessions.sorted { $0.lastModified > $1.lastModified }
            let resolvedPath = sorted.first.map(provider.resolvedProjectPath(for:)) ?? key
            var cost = 0.0
            var tokens = 0
            var messages = 0
            var toolUseCount = 0
            for session in sorted {
                if let stats = statsMap[session.id] {
                    cost += stats.estimatedCost
                    tokens += stats.totalTokens
                    messages += stats.messageCount
                    toolUseCount += stats.toolUseTotal
                }
            }
            return ProjectGroup(projectPath: key, sessions: sorted, resolvedPath: resolvedPath, totalCost: cost,
                                totalTokens: tokens, totalMessages: messages, toolUseCount: toolUseCount)
        }
        .sorted { ($0.sessions.first?.lastModified ?? .distantPast) > ($1.sessions.first?.lastModified ?? .distantPast) }
    }

    @Published var expandedProjects: Set<String> = []

    func isProjectExpanded(_ projectPath: String) -> Bool {
        if !searchText.isEmpty { return true }
        return expandedProjects.contains(projectPath)
    }

    func toggleProjectExpanded(_ projectPath: String) {
        if expandedProjects.contains(projectPath) {
            expandedProjects.remove(projectPath)
        } else {
            expandedProjects.insert(projectPath)
        }
    }

    func selectSession(_ session: Session) {
        selectedSession = session

        if let cached = store.parsedStats[session.id] {
            selectedSessionStats = cached
            isLoadingStats = false
        } else {
            loadStats(for: session)
        }
    }

    func openTranscript(for session: Session, searchQuery: String? = nil, snippetContext: String? = nil) {
        // Track if entered from list (selectedSession was nil) or from detail
        transcriptEnteredFromList = (selectedSession == nil || selectedSessionStats == nil)
        selectedSession = session
        transcriptSearchQuery = searchQuery
        transcriptSnippetContext = snippetContext
        showTranscript = true
    }

    func closeTranscript() {
        showTranscript = false
        transcriptSearchQuery = nil
        transcriptSnippetContext = nil
        transcriptSearchText = ""
        transcriptMatchIndex = 0
        transcriptInitialLoadDone = false
        if transcriptEnteredFromList {
            selectedSession = nil
            selectedSessionStats = nil
        }
        transcriptEnteredFromList = false
    }

    func loadStats(for session: Session) {
        isLoadingStats = true
        selectedSessionStats = nil

        let provider = store.provider
        let path = session.filePath
        Task.detached {
            let stats = provider.parseSession(at: path)
            await MainActor.run { [weak self] in
                self?.selectedSessionStats = stats
                self?.isLoadingStats = false
            }
        }
    }

    func quickStat(for session: Session) -> SessionQuickStats? {
        store.quickStats[session.id]
    }

    func loadMessages(for session: Session) async -> [TranscriptDisplayMessage] {
        await loadMessages(at: session.filePath)
    }

    func loadMessages(at path: String) async -> [TranscriptDisplayMessage] {
        let provider = store.provider
        return await Task.detached {
            provider.parseMessages(at: path)
        }.value
    }

    func loadTrendData(for session: Session, granularity: TrendGranularity) async -> [TrendDataPoint] {
        let provider = store.provider
        let path = session.filePath
        return await Task.detached {
            provider.parseTrendData(from: path, granularity: granularity)
        }.value
    }

    func openNewSession(_ session: Session) {
        if TerminalSetupCoordinator.shared.prepareForTerminalAction() {
            return
        }
        store.provider.openNewSession(session)
    }

    func resumeSession(_ session: Session) {
        if TerminalSetupCoordinator.shared.prepareForTerminalAction() {
            return
        }
        store.provider.resumeSession(session)
    }

    func resumeCommand(for session: Session) -> String {
        store.provider.resumeCommand(for: session)
    }

    func openNewSession(inDirectory path: String) {
        if TerminalSetupCoordinator.shared.prepareForTerminalAction() {
            return
        }
        store.provider.openNewSession(inDirectory: path)
    }

    // MARK: - Selection & Delete

    func toggleSelect(_ session: Session) {
        if selectedIds.contains(session.id) {
            selectedIds.remove(session.id)
        } else {
            selectedIds.insert(session.id)
        }
    }

    func selectAll() {
        selectedIds = Set(filteredSessions.map(\.id))
    }

    func exitSelecting() {
        isSelecting = false
        selectedIds.removeAll()
    }

    func deleteSessions(_ ids: Set<String>) {
        store.deleteSessions(ids)
        selectedIds.subtract(ids)
        if selectedIds.isEmpty {
            isSelecting = false
        }
    }

    func deleteSession(_ session: Session) {
        deleteSessions([session.id])
    }

    // MARK: - Aggregate stats

    var totalSessions: Int { store.sessions.count }
}
