import Foundation
import SwiftUI

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var selectedSession: Session?
    @Published var selectedSessionStats: SessionStats?
    @Published var isLoadingStats = false
    @Published var searchText = ""
    @Published var quickStats: [String: TranscriptParser.QuickStats] = [:]
    @Published var isSelecting = false
    @Published var selectedIds: Set<String> = []

    var filteredSessions: [Session] {
        if searchText.isEmpty { return sessions }
        let query = searchText.lowercased()
        return sessions.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.id.lowercased().contains(query)
        }
    }

    func loadSessions() {
        sessions = SessionScanner.shared.scanSessions()
        loadQuickStats()
    }

    func selectSession(_ session: Session) {
        selectedSession = session
        loadStats(for: session)
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

    /// Parse quick stats for visible sessions in background
    private func loadQuickStats() {
        let sessionsToLoad = sessions.prefix(50)
        for session in sessionsToLoad {
            if quickStats[session.id] != nil { continue }
            Task.detached { [weak self] in
                let stats = TranscriptParser.shared.parseSessionQuick(at: session.filePath)
                await MainActor.run {
                    self?.quickStats[session.id] = stats
                }
            }
        }
    }

    func quickStat(for session: Session) -> TranscriptParser.QuickStats? {
        quickStats[session.id]
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
        let fm = FileManager.default
        for session in sessions where ids.contains(session.id) {
            try? fm.removeItem(atPath: session.filePath)
            quickStats.removeValue(forKey: session.id)
        }
        sessions.removeAll { ids.contains($0.id) }
        selectedIds.subtract(ids)
        if selectedIds.isEmpty {
            isSelecting = false
        }
    }

    func deleteSession(_ session: Session) {
        deleteSessions([session.id])
    }

    // MARK: - Aggregate stats

    var totalSessions: Int { sessions.count }

    var projectGroups: [(project: String, count: Int, sessions: [Session])] {
        let grouped = Dictionary(grouping: filteredSessions) { $0.projectPath }
        return grouped.map { (project: $0.value.first?.displayName ?? $0.key, count: $0.value.count, sessions: $0.value) }
            .sorted { $0.count > $1.count }
    }
}
