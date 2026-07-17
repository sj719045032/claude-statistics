import Foundation
import ClaudeStatisticsKit
import SwiftUI
import Combine

struct ProjectGroup: Identifiable {
    var id: String { projectPath }
    let projectPath: String
    let sessions: [Session]
    let families: [SessionFamily]
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

    init(
        projectPath: String,
        sessions: [Session],
        resolvedPath: String,
        totalCost: Double = 0,
        totalTokens: Int = 0,
        totalMessages: Int = 0,
        toolUseCount: Int = 0,
        families: [SessionFamily]? = nil
    ) {
        self.projectPath = projectPath
        self.sessions = sessions
        self.families = families ?? SessionHierarchy.families(from: sessions)
        self.resolvedPath = resolvedPath
        self.totalCost = totalCost
        self.totalTokens = totalTokens
        self.totalMessages = totalMessages
        self.toolUseCount = toolUseCount
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
    private var selectionAnchorId: String?
    private var selectionAnchorProjectPath: String?
    private var detailHistory: [Session] = []

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
    @Published private(set) var recentFamilies: [SessionFamily] = []
    @Published private(set) var filteredSessions: [Session] = []
    @Published private(set) var projectGroups: [ProjectGroup] = []
    private var allFamiliesByRootID: [String: SessionFamily] = [:]

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
        let directlyFiltered: [Session]
        if searchText.isEmpty {
            directlyFiltered = store.sessions
        } else {
            var matchedIds = Set<String>()
            var result: [Session] = []
            for session in store.sessions {
                if SearchUtils.textMatches(query: searchText, in: session.displayName) ||
                    SearchUtils.textMatches(query: searchText, in: session.externalID) ||
                    SearchUtils.textMatches(query: searchText, in: session.agentDisplayName ?? "") ||
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
            directlyFiltered = result
        }
        let filtered = searchText.isEmpty
            ? directlyFiltered
            : SessionHierarchy.includingAncestors(of: directlyFiltered, from: store.sessions)
        let allFamilies = SessionHierarchy.families(from: store.sessions)
        allFamiliesByRootID = Dictionary(
            allFamilies.map { ($0.root.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        filteredSessions = filtered
        recentFamilies = searchText.isEmpty
            ? Array(allFamilies.prefix(3))
            : []

        // projectGroups (with pre-computed cost)
        let statsMap = store.parsedStats
        let provider = store.provider
        let grouped = Dictionary(grouping: SessionHierarchy.families(from: filtered)) {
            $0.root.cwd ?? $0.root.projectPath
        }
        projectGroups = grouped.map { key, families in
            let sortedFamilies = families.sorted {
                if $0.latestModified == $1.latestModified { return $0.id > $1.id }
                return $0.latestModified > $1.latestModified
            }
            let familySessions = sortedFamilies.flatMap(\.allSessions)
            let sorted = familySessions.sorted { $0.lastModified > $1.lastModified }
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
            return ProjectGroup(
                projectPath: key,
                sessions: sorted,
                resolvedPath: resolvedPath,
                totalCost: cost,
                totalTokens: tokens,
                totalMessages: messages,
                toolUseCount: toolUseCount,
                families: sortedFamilies
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

    func metrics(for family: SessionFamily) -> SessionListMetrics? {
        SessionListMetrics.aggregate(
            sessions: family.allSessions,
            parsedStats: store.parsedStats,
            quickStats: store.quickStats
        )
    }

    func subagents(for session: Session) -> [Session] {
        allFamiliesByRootID[session.id]?.descendants ?? []
    }

    func selectSession(_ session: Session) {
        detailHistory.removeAll()
        showSessionDetail(session)
    }

    func selectSubagent(_ session: Session) {
        guard selectedSession?.id != session.id else { return }
        if let selectedSession {
            detailHistory.append(selectedSession)
        }
        showSessionDetail(session)
    }

    func closeSessionDetail() {
        if let previous = detailHistory.popLast() {
            showSessionDetail(previous)
        } else {
            selectedSession = nil
            selectedSessionStats = nil
            isLoadingStats = false
        }
    }

    private func showSessionDetail(_ session: Session) {
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

        if session.isArchived {
            // For archived sessions, use the cached stats from parsedStats
            selectedSessionStats = store.parsedStats[session.id]
            isLoadingStats = false
            return
        }

        let provider = store.provider
        let path = session.filePath
        Task.detached {
            let stats = provider.parseSession(at: path)
            await MainActor.run { [weak self] in
                guard self?.selectedSession?.id == session.id else { return }
                self?.selectedSessionStats = stats
                self?.isLoadingStats = false
            }
        }
    }

    func quickStat(for session: Session) -> SessionQuickStats? {
        store.quickStats[session.id]
    }

    func loadMessages(for session: Session) async -> [TranscriptDisplayMessage] {
        if !session.isArchived {
            return await loadMessages(at: session.filePath)
        }
        // Archived session: decompress transcript from DB
        let store = self.store
        return await Task.detached {
            guard let data = store.resolveTranscriptData(for: session) else { return [] }
            // Extract session UUID from the composite session ID (format: "project::uuid")
            let sessionId: String
            if let range = session.id.range(of: "::", options: .backwards) {
                sessionId = String(session.id[range.upperBound...])
            } else {
                sessionId = session.id
            }
            return TranscriptParser.shared.parseMessages(fromData: data, sessionId: sessionId)
        }.value
    }

    func loadMessages(at path: String) async -> [TranscriptDisplayMessage] {
        let provider = store.provider
        return await Task.detached {
            provider.parseMessages(at: path)
        }.value
    }

    func loadTrendData(for session: Session, granularity: TrendGranularity) async -> [TrendDataPoint] {
        if !session.isArchived {
            let provider = store.provider
            let path = session.filePath
            return await Task.detached {
                provider.parseTrendData(from: path, granularity: granularity)
            }.value
        }
        // Archived session: decompress transcript from DB
        let store = self.store
        return await Task.detached {
            guard let data = store.resolveTranscriptData(for: session) else { return [] }
            return TranscriptParser.shared.parseTrendData(fromData: data, granularity: granularity)
        }.value
    }

    func openNewSession(_ session: Session) {
        if TerminalSetupCoordinator.shared.prepareForTerminalAction() {
            return
        }
        store.provider.openNewSession(session)
    }

    func resumeSession(_ session: Session) {
        guard session.isResumable else { return }
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

    func toggleSelect(_ session: Session, extendingRange: Bool = false) {
        if extendingRange,
           let anchorId = selectionAnchorId,
           let rangeIds = selectionRangeIds(from: anchorId, to: session.id)
        {
            selectedIds.formUnion(familySessionIDs(forRootIDs: rangeIds))
            return
        }

        let ids = familySessionIDs(for: session)
        if ids.isSubset(of: selectedIds) {
            selectedIds.subtract(ids)
        } else {
            selectedIds.formUnion(ids)
        }
        selectionAnchorId = session.id
        selectionAnchorProjectPath = nil
    }

    func toggleSelectProject(_ group: ProjectGroup, extendingRange: Bool = false) {
        if extendingRange,
           let anchorPath = selectionAnchorProjectPath,
           let rangeIds = projectSelectionRangeIds(from: anchorPath, to: group.projectPath)
        {
            selectedIds.formUnion(rangeIds)
            return
        }

        let ids = group.families.reduce(into: Set<String>()) { result, family in
            result.formUnion(familySessionIDs(for: family.root))
        }
        if ids.isSubset(of: selectedIds) {
            selectedIds.subtract(ids)
        } else {
            selectedIds.formUnion(ids)
        }
        selectionAnchorId = group.families.first?.root.id ?? selectionAnchorId
        selectionAnchorProjectPath = group.projectPath
    }

    func selectAll() {
        selectedIds = projectGroups
            .flatMap(\.families)
            .reduce(into: Set<String>()) { result, family in
                result.formUnion(familySessionIDs(for: family.root))
            }
        selectionAnchorId = projectGroups.first?.families.first?.root.id
        selectionAnchorProjectPath = projectGroups.first?.projectPath
    }

    func exitSelecting() {
        isSelecting = false
        selectedIds.removeAll()
        selectionAnchorId = nil
        selectionAnchorProjectPath = nil
    }

    func projectSelectionState(for group: ProjectGroup) -> ProjectSelectionState {
        let ids = group.families.reduce(into: Set<String>()) { result, family in
            result.formUnion(familySessionIDs(for: family.root))
        }
        guard !ids.isEmpty else { return .none }
        if ids.isSubset(of: selectedIds) { return .all }
        if ids.isDisjoint(with: selectedIds) { return .none }
        return .partial
    }

    func projectSelectionRangePaths(to projectPath: String) -> Set<String> {
        guard let anchorPath = selectionAnchorProjectPath else { return [] }
        return projectSelectionRangePaths(from: anchorPath, to: projectPath) ?? []
    }

    func sessionSelectionRangeIds(to sessionId: String) -> Set<String> {
        guard let anchorId = selectionAnchorId else { return [] }
        return selectionRangeIds(from: anchorId, to: sessionId) ?? []
    }

    func familySessionIDs(for session: Session) -> Set<String> {
        allFamiliesByRootID[session.id]?.sessionIDs ?? [session.id]
    }

    func isFamilySelected(_ session: Session) -> Bool {
        familySessionIDs(for: session).isSubset(of: selectedIds)
    }

    var selectedFamilyCount: Int {
        projectGroups
            .flatMap(\.families)
            .filter { familySessionIDs(for: $0.root).isSubset(of: selectedIds) }
            .count
    }

    func deleteSessions(_ ids: Set<String>) {
        store.deleteSessions(ids)
        selectedIds.subtract(ids)
        if selectedIds.isEmpty {
            isSelecting = false
            selectionAnchorId = nil
            selectionAnchorProjectPath = nil
        }
    }

    func deleteSession(_ session: Session) {
        deleteSessions(familySessionIDs(for: session))
    }

    // MARK: - Aggregate stats

    var totalSessions: Int { store.sessions.count }
    var displayedSessionCount: Int {
        projectGroups.reduce(0) { $0 + $1.families.count }
    }

    private func selectionRangeIds(from anchorId: String, to sessionId: String) -> Set<String>? {
        let orderedIds = displayedSelectableSessionIds()
        guard
            let anchorIndex = orderedIds.firstIndex(of: anchorId),
            let sessionIndex = orderedIds.firstIndex(of: sessionId)
        else {
            return nil
        }

        let bounds = min(anchorIndex, sessionIndex)...max(anchorIndex, sessionIndex)
        return Set(orderedIds[bounds])
    }

    private func projectSelectionRangeIds(from anchorPath: String, to projectPath: String) -> Set<String>? {
        guard let paths = projectSelectionRangePaths(from: anchorPath, to: projectPath) else {
            return nil
        }

        return Set(projectGroups
            .filter { paths.contains($0.projectPath) }
            .flatMap(\.families)
            .reduce(into: Set<String>()) { result, family in
                result.formUnion(familySessionIDs(for: family.root))
            })
    }

    private func projectSelectionRangePaths(from anchorPath: String, to projectPath: String) -> Set<String>? {
        guard
            let anchorIndex = projectGroups.firstIndex(where: { $0.projectPath == anchorPath }),
            let projectIndex = projectGroups.firstIndex(where: { $0.projectPath == projectPath })
        else {
            return nil
        }

        let bounds = min(anchorIndex, projectIndex)...max(anchorIndex, projectIndex)
        return Set(projectGroups[bounds].map(\.projectPath))
    }

    private func displayedSelectableSessionIds() -> [String] {
        projectGroups.flatMap { group -> [String] in
            guard isProjectExpanded(group.projectPath) else { return [] }
            return group.families.map(\.root.id)
        }
    }

    private func familySessionIDs(forRootIDs rootIDs: Set<String>) -> Set<String> {
        rootIDs.reduce(into: Set<String>()) { result, rootID in
            guard let session = store.sessions.first(where: { $0.id == rootID }) else { return }
            result.formUnion(familySessionIDs(for: session))
        }
    }
}

enum ProjectSelectionState {
    case none
    case partial
    case all
}
