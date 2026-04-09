import Foundation
import SQLite3

// MARK: - DatabaseService

final class DatabaseService {
    static let shared = DatabaseService()

    private var db: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {}

    // MARK: - Open / Close

    func open() {
        guard db == nil else { return }

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClaudeStatistics")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("data.db").path

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("[DatabaseService] Failed to open database: \(String(cString: sqlite3_errmsg(db!)))")
            db = nil
            return
        }

        // Performance pragmas
        execute("PRAGMA journal_mode = WAL")
        execute("PRAGMA synchronous = NORMAL")

        createTables()
        migrateIfNeeded()
    }

    func close() {
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    // MARK: - Schema

    private func createTables() {
        // FTS5 for message content search
        execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
                session_id UNINDEXED,
                role UNINDEXED,
                content,
                timestamp UNINDEXED
            )
        """)

        // Session stats cache (fingerprint + serialized stats)
        execute("""
            CREATE TABLE IF NOT EXISTS session_cache(
                session_id TEXT PRIMARY KEY,
                file_size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                quick_json TEXT,
                stats_json TEXT
            )
        """)
    }

    /// Current schema version — bump to force full reparse of session cache
    private static let currentSchemaVersion: Int32 = 3

    private func migrateIfNeeded() {
        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            version = sqlite3_column_int(stmt, 0)
        }
        sqlite3_finalize(stmt)

        if version < Self.currentSchemaVersion {
            // Clear session cache to force reparse with new hourSlices field
            execute("DELETE FROM session_cache")
            execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
        }
    }

    /// Drop all data and recreate tables (for schema migration or corruption recovery)
    func resetDatabase() {
        execute("DROP TABLE IF EXISTS messages")
        execute("DROP TABLE IF EXISTS session_cache")
        createTables()
    }

    // MARK: - Stats Cache

    struct CachedSession {
        let sessionId: String
        let fileSize: Int64
        let mtime: Date
        let quickStats: TranscriptParser.QuickStats?
        let sessionStats: SessionStats?
    }

    /// Load all cached sessions from the database
    func loadAllCached() -> [String: CachedSession] {
        guard let db else { return [:] }

        let sql = "SELECT session_id, file_size, mtime, quick_json, stats_json FROM session_cache"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        let decoder = JSONDecoder()
        var result: [String: CachedSession] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionId = String(cString: sqlite3_column_text(stmt, 0))
            let fileSize = sqlite3_column_int64(stmt, 1)
            let mtime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))

            var quick: TranscriptParser.QuickStats?
            if let ptr = sqlite3_column_text(stmt, 3) {
                let json = Data(String(cString: ptr).utf8)
                quick = try? decoder.decode(TranscriptParser.QuickStats.self, from: json)
            }

            var stats: SessionStats?
            if let ptr = sqlite3_column_text(stmt, 4) {
                let json = Data(String(cString: ptr).utf8)
                stats = try? decoder.decode(SessionStats.self, from: json)
            }

            result[sessionId] = CachedSession(
                sessionId: sessionId,
                fileSize: fileSize,
                mtime: mtime,
                quickStats: quick,
                sessionStats: stats
            )
        }

        return result
    }

    /// Check if a session needs reparsing (fingerprint mismatch or not cached)
    func needsReparse(sessionId: String, fileSize: Int64, mtime: Date, cache: [String: CachedSession]) -> Bool {
        guard let cached = cache[sessionId] else { return true }
        return cached.fileSize != fileSize ||
               abs(cached.mtime.timeIntervalSince(mtime)) > 1.0
    }

    /// Save quick stats for a session (upsert)
    func saveQuickStats(sessionId: String, fileSize: Int64, mtime: Date, stats: TranscriptParser.QuickStats) {
        guard let db else { return }

        let encoder = JSONEncoder()
        guard let json = try? encoder.encode(stats),
              let jsonStr = String(data: json, encoding: .utf8) else { return }

        let sql = """
            INSERT INTO session_cache(session_id, file_size, mtime, quick_json)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
                file_size = excluded.file_size,
                mtime = excluded.mtime,
                quick_json = excluded.quick_json
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 2, fileSize)
        sqlite3_bind_double(stmt, 3, mtime.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 4, jsonStr, -1, sqliteTransient)
        sqlite3_step(stmt)
    }

    /// Save full session stats (update existing row)
    func saveSessionStats(sessionId: String, stats: SessionStats) {
        guard let db else { return }

        let encoder = JSONEncoder()
        guard let json = try? encoder.encode(stats),
              let jsonStr = String(data: json, encoding: .utf8) else { return }

        let sql = "UPDATE session_cache SET stats_json = ? WHERE session_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, jsonStr, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, sessionId, -1, sqliteTransient)
        sqlite3_step(stmt)
    }

    /// Remove cached data for deleted sessions
    func removeSessions(_ sessionIds: Set<String>) {
        guard let db, !sessionIds.isEmpty else { return }

        execute("BEGIN TRANSACTION")
        for id in sessionIds {
            let sql1 = "DELETE FROM session_cache WHERE session_id = ?"
            var stmt1: OpaquePointer?
            if sqlite3_prepare_v2(db, sql1, -1, &stmt1, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt1, 1, id, -1, sqliteTransient)
                sqlite3_step(stmt1)
                sqlite3_finalize(stmt1)
            }

            let sql2 = "DELETE FROM messages WHERE session_id = ?"
            var stmt2: OpaquePointer?
            if sqlite3_prepare_v2(db, sql2, -1, &stmt2, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt2, 1, id, -1, sqliteTransient)
                sqlite3_step(stmt2)
                sqlite3_finalize(stmt2)
            }
        }
        execute("COMMIT")
    }

    // MARK: - Search Index

    /// Index all messages from a session's JSONL file into FTS
    func indexSession(sessionId: String, filePath: String) {
        guard let db else { return }
        guard let data = FileManager.default.contents(atPath: filePath) else { return }

        let content = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()

        // Remove old entries first
        let delSQL = "DELETE FROM messages WHERE session_id = ?"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, delSQL, -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, sessionId, -1, sqliteTransient)
            sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }

        // Insert in transaction
        execute("BEGIN TRANSACTION")

        let insertSQL = "INSERT INTO messages(session_id, role, content, timestamp) VALUES(?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            execute("ROLLBACK")
            return
        }

        func insertRow(_ role: String, _ text: String, _ timestamp: String) {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, sessionId, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, role, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 3, text, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 4, timestamp, -1, sqliteTransient)
            sqlite3_step(stmt)
        }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let entry = try? decoder.decode(TranscriptEntry.self, from: lineData) else { continue }

            let ts = entry.timestamp ?? ""

            switch entry.type {
            case "queue-operation":
                if entry.operation == "enqueue", let text = entry.content,
                   text.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 {
                    insertRow("user", text.trimmingCharacters(in: .whitespacesAndNewlines), ts)
                }

            case "user", "human":
                guard let text = Self.extractMessageText(from: entry) else { continue }
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleaned.count > 2 else { continue }
                if cleaned.hasPrefix("<") && (
                    cleaned.contains("<ide_opened_file>") ||
                    cleaned.contains("<command-message>") ||
                    cleaned.contains("<local-command-caveat>") ||
                    cleaned.contains("<system-reminder>")
                ) { continue }
                insertRow("user", Self.stripMarkdownForIndex(cleaned), ts)

            case "assistant":
                // Index text content (strip markdown so FTS matches plain text)
                if let text = Self.extractMessageText(from: entry) {
                    let cleaned = Self.stripMarkdownForIndex(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    if cleaned.count > 2 { insertRow("assistant", cleaned, ts) }
                }
                // Index tool use names + tool result content
                if let items = entry.message?.content {
                    for item in items {
                        if case .toolUse(let tc) = item, let name = tc.name {
                            var indexText = name
                            if let dict = tc.input?.value as? [String: Any] {
                                if let p = dict["file_path"] as? String { indexText += " " + p }
                                if let c = dict["command"] as? String { indexText += " " + String(c.prefix(500)) }
                                if let p = dict["pattern"] as? String { indexText += " " + p }
                                // Index Write content and Edit old/new strings
                                if let c = dict["content"] as? String { indexText += " " + String(c.prefix(2000)) }
                                if let s = dict["old_string"] as? String { indexText += " " + String(s.prefix(1000)) }
                                if let s = dict["new_string"] as? String { indexText += " " + String(s.prefix(1000)) }
                            }
                            insertRow("tool", Self.stripMarkdownForIndex(indexText), ts)
                        }
                        if case .toolResult(let tr) = item {
                            if let resultStr = tr.content?.stringValue, resultStr.count > 2 {
                                // Truncate large results for FTS
                                let truncated = resultStr.count > 500 ? String(resultStr.prefix(500)) : resultStr
                                insertRow("tool", truncated, ts)
                            }
                        }
                    }
                }

            default: break
            }
        }

        sqlite3_finalize(stmt)
        execute("COMMIT")
    }

    /// Search results grouped by session
    struct SearchResult {
        let sessionId: String
        let snippet: String   // matched text with «» markers around highlights
        let role: String
    }

    /// Full-text search across all indexed messages. Returns best match per session.
    func search(query: String) -> [SearchResult] {
        guard let db, !query.isEmpty else { return [] }

        // Sanitize query for FTS5: escape double quotes, wrap terms
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }

        let sql = """
            SELECT session_id, snippet(messages, 2, '«', '»', '…', 20), role
            FROM messages
            WHERE content MATCH ?
            ORDER BY rank
            LIMIT 200
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sanitized, -1, sqliteTransient)

        // Collect all matches, keep best (first) per session, preserving SQLite rank order
        var seenIds = Set<String>()
        var results: [SearchResult] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionId = String(cString: sqlite3_column_text(stmt, 0))
            let snippet = String(cString: sqlite3_column_text(stmt, 1))
            let role = String(cString: sqlite3_column_text(stmt, 2))

            // Keep the first (highest-ranked) result per session
            if !seenIds.contains(sessionId) {
                seenIds.insert(sessionId)
                results.append(SearchResult(
                    sessionId: sessionId,
                    snippet: snippet,
                    role: role
                ))
            }
        }

        return results
    }

    // MARK: - Helpers

    private func execute(_ sql: String) {
        guard let db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg {
                print("[DatabaseService] SQL error: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }

    private static func stripMarkdownForIndex(_ text: String) -> String {
        SearchUtils.stripMarkdown(text)
    }

    /// Extract all text content from a message entry (user or assistant)
    private static func extractMessageText(from entry: TranscriptEntry) -> String? {
        guard let message = entry.message else { return nil }

        // Plain string content
        if let str = message.contentString {
            return str
        }

        // Array content — collect all text blocks
        if let content = message.content {
            let texts = content.compactMap { item -> String? in
                if case .text(let tc) = item { return tc.text }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }

        return nil
    }

    private func sanitizeFTSQuery(_ raw: String) -> String {
        SearchUtils.ftsQuery(raw)
    }
}
