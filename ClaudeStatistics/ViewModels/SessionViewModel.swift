import Foundation
import SwiftUI

@MainActor
final class SessionViewModel: ObservableObject {
    let store: SessionDataStore

    @Published var selectedSession: Session?
    @Published var selectedSessionStats: SessionStats?
    @Published var isLoadingStats = false
    @Published var searchText = ""
    @Published var isSelecting = false
    @Published var selectedIds: Set<String> = []

    init(store: SessionDataStore) {
        self.store = store
    }

    var filteredSessions: [Session] {
        if searchText.isEmpty { return store.sessions }
        let query = searchText.lowercased()
        return store.sessions.filter { session in
            session.displayName.lowercased().contains(query) ||
            session.id.lowercased().contains(query) ||
            (store.quickStats[session.id]?.topic?.lowercased().contains(query) == true)
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

    func loadStats(for session: Session) {
        isLoadingStats = true
        selectedSessionStats = nil

        Task.detached { [weak self] in
            let stats = TranscriptParser.shared.parseSession(at: session.filePath)
            await MainActor.run {
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

    var projectGroups: [(project: String, count: Int, sessions: [Session])] {
        let grouped = Dictionary(grouping: filteredSessions) { $0.projectPath }
        return grouped.map { (project: $0.value.first?.displayName ?? $0.key, count: $0.value.count, sessions: $0.value) }
            .sorted { $0.count > $1.count }
    }
}
