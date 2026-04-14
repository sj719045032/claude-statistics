import Foundation
import SQLite3

final class CodexSessionScanner {
    static let shared = CodexSessionScanner()

    private let dbPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/state_5.sqlite")

    private init() {}

    func scanSessions() -> [Session] {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, rollout_path, title, cwd, created_at, updated_at
            FROM threads
            WHERE archived = 0 AND rollout_path IS NOT NULL
            ORDER BY updated_at DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var sessions: [Session] = []
        let fm = FileManager.default

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnText(stmt, at: 0),
                  let filePath = columnText(stmt, at: 1),
                  !filePath.isEmpty,
                  fm.fileExists(atPath: filePath),
                  let attrs = try? fm.attributesOfItem(atPath: filePath) else {
                continue
            }

            let title = columnText(stmt, at: 2) ?? ""
            let cwd = columnText(stmt, at: 3) ?? ""
            let createdAt = sqlite3_column_int64(stmt, 4)
            let updatedAt = sqlite3_column_int64(stmt, 5)

            let fileSize = attrs[.size] as? Int64 ?? 0
            guard fileSize > 0 else { continue }

            let startTime = createdAt > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAt)) : nil
            let fallbackModified = updatedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(updatedAt)) : Date.distantPast
            let lastModified = attrs[.modificationDate] as? Date ?? fallbackModified
            let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectPath = !trimmedCwd.isEmpty ? trimmedCwd : fallbackProjectPath(title: title, filePath: filePath, sessionId: id)

            sessions.append(Session(
                id: id,
                externalID: id,
                provider: .codex,
                projectPath: projectPath,
                filePath: filePath,
                startTime: startTime,
                lastModified: lastModified,
                fileSize: fileSize,
                cwd: trimmedCwd.isEmpty ? nil : trimmedCwd
            ))
        }

        return sessions.sorted { $0.lastModified > $1.lastModified }
    }

    private func columnText(_ stmt: OpaquePointer?, at index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    private func fallbackProjectPath(title: String, filePath: String, sessionId: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let parent = (filePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? sessionId : parent
    }
}
