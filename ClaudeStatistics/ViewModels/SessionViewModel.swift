import Foundation
import SwiftUI
import Combine

struct ProjectGroup: Identifiable {
    var id: String { projectPath }
    let projectPath: String
    let sessions: [Session]

    var displayName: String {
        let path = sessions.first?.displayName ?? projectPath
        return (path as NSString).lastPathComponent
    }

    var shortPath: String {
        let home = NSHomeDirectory()
        let path = sessions.first?.cwd
            ?? TerminalLauncher.decodeProjectPath(projectPath)
            ?? projectPath
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    var cwdPath: String {
        sessions.first?.cwd
            ?? TerminalLauncher.decodeProjectPath(projectPath)
            ?? NSHomeDirectory()
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

    private var searchCancellable: AnyCancellable?

    init(store: SessionDataStore) {
        self.store = store

        // Debounced FTS content search — updates searchSnippets reactively
        searchCancellable = $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] text in
                guard let self else { return }
                if text.count >= 2 {
                    let results = self.store.searchMessages(query: text)
                    self.searchSnippets = Dictionary(
                        results.map { ($0.sessionId, $0.snippet) },
                        uniquingKeysWith: { first, _ in first }
                    )
                } else {
                    if !self.searchSnippets.isEmpty {
                        self.searchSnippets = [:]
                    }
                }
            }
    }

    var recentSessions: [Session] {
        guard searchText.isEmpty else { return [] }
        return Array(store.sessions.prefix(3))
    }

    var filteredSessions: [Session] {
        if searchText.isEmpty { return store.sessions }

        // 1. Metadata matches (name, topic, id)
        var matchedIds = Set<String>()
        var result: [Session] = []

        for session in store.sessions {
            if SearchUtils.textMatches(query: searchText, in: session.displayName) ||
                SearchUtils.textMatches(query: searchText, in: session.id) ||
                SearchUtils.textMatches(query: searchText, in: store.quickStats[session.id]?.topic ?? "") ||
                SearchUtils.textMatches(query: searchText, in: store.quickStats[session.id]?.sessionName ?? "")
            {
                result.append(session)
                matchedIds.insert(session.id)
            }
        }

        // 2. Include FTS content matches (snippets populated by Combine pipeline)
        if !searchSnippets.isEmpty {
            let sessionLookup = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, $0) })
            for sessionId in searchSnippets.keys {
                if !matchedIds.contains(sessionId), let session = sessionLookup[sessionId] {
                    result.append(session)
                    matchedIds.insert(sessionId)
                }
            }
        }

        return result
    }

    var projectGroups: [ProjectGroup] {
        let grouped = Dictionary(grouping: filteredSessions) { $0.cwd ?? $0.projectPath }
        return grouped.map { key, sessions in
            ProjectGroup(
                projectPath: key,
                sessions: sessions.sorted { $0.lastModified > $1.lastModified }
            )
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

        let path = session.filePath
        Task.detached {
            let stats = TranscriptParser.shared.parseSession(at: path)
            await MainActor.run { [weak self] in
                self?.selectedSessionStats = stats
                self?.isLoadingStats = false
            }
        }
    }

    func quickStat(for session: Session) -> TranscriptParser.QuickStats? {
        store.quickStats[session.id]
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
