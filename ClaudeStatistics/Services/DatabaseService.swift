import Foundation
import SQLite3

// MARK: - DatabaseService

final class DatabaseService {
    static let shared = DatabaseService()

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {}

    // MARK: - Open / Close

    func open() {
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    // MARK: - Schema

    private func createTables() {
        // FTS5 for message content search
        execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
                provider UNINDEXED,
                session_id UNINDEXED,
                role UNINDEXED,
                content,
                timestamp UNINDEXED
            )
        """)

        // Session stats cache (fingerprint + serialized stats)
        execute("""
            CREATE TABLE IF NOT EXISTS session_cache(
                provider TEXT NOT NULL,
                session_id TEXT NOT NULL,
                file_size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                quick_json TEXT,
                stats_json TEXT,
                PRIMARY KEY (provider, session_id)
            )
        """)
    }

    /// Current schema version — bump to force full reparse of session cache
    private static let currentSchemaVersion: Int32 = 5

    private func migrateIfNeeded() {
        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            version = sqlite3_column_int(stmt, 0)
        }
        sqlite3_finalize(stmt)

        if version < Self.currentSchemaVersion {
            resetDatabase()
            execute("PRAGMA user_version = \(Self.currentSchemaVersion)")
        }
    }

    /// Drop all data and recreate tables (for schema migration or corruption recovery)
    func resetDatabase() {
        lock.lock()
        defer { lock.unlock() }
        execute("DROP TABLE IF EXISTS messages")
        execute("DROP TABLE IF EXISTS session_cache")
        createTables()
    }

    // MARK: - Stats Cache

    struct CachedSession {
        let provider: ProviderKind
        let sessionId: String
        let fileSize: Int64
        let mtime: Date
        let quickStats: SessionQuickStats?
        let sessionStats: SessionStats?
    }

    /// Load all cached sessions from the database
    func loadAllCached(provider: ProviderKind) -> [String: CachedSession] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [:] }

        let sql = """
            SELECT session_id, file_size, mtime, quick_json, stats_json
            FROM session_cache
            WHERE provider = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)

        let decoder = JSONDecoder()
        var result: [String: CachedSession] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionId = String(cString: sqlite3_column_text(stmt, 0))
            let fileSize = sqlite3_column_int64(stmt, 1)
            let mtime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))

            var quick: SessionQuickStats?
            if let ptr = sqlite3_column_text(stmt, 3) {
                let json = Data(String(cString: ptr).utf8)
                quick = try? decoder.decode(SessionQuickStats.self, from: json)
            }

            var stats: SessionStats?
            if let ptr = sqlite3_column_text(stmt, 4) {
                let json = Data(String(cString: ptr).utf8)
                stats = try? decoder.decode(SessionStats.self, from: json)
            }

            result[sessionId] = CachedSession(
                provider: provider,
                sessionId: sessionId,
                fileSize: fileSize,
                mtime: mtime,
                quickStats: quick,
                sessionStats: stats
            )
        }

        return result
    }

    func indexedSessionIds(provider: ProviderKind) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }

        let sql = """
            SELECT DISTINCT session_id
            FROM messages
            WHERE provider = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)

        var sessionIds = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let text = sqlite3_column_text(stmt, 0) else { continue }
            sessionIds.insert(String(cString: text))
        }
        return sessionIds
    }

    /// Check if a session needs reparsing (fingerprint mismatch, not cached, or missing full stats)
    func needsReparse(sessionId: String, fileSize: Int64, mtime: Date, cache: [String: CachedSession]) -> Bool {
        guard let cached = cache[sessionId] else { return true }
        if cached.sessionStats == nil { return true }
        return cached.fileSize != fileSize ||
               abs(cached.mtime.timeIntervalSince(mtime)) > 1.0
    }

    /// Save quick stats for a session.
    /// For existing fully parsed rows, keep the last committed fingerprint intact until
    /// full stats + search index are atomically replaced.
    func saveQuickStats(provider: ProviderKind, sessionId: String, fileSize: Int64, mtime: Date, stats: SessionQuickStats) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let encoder = JSONEncoder()
        guard let json = try? encoder.encode(stats),
              let jsonStr = String(data: json, encoding: .utf8) else { return }

        let sql = """
            INSERT INTO session_cache(provider, session_id, file_size, mtime, quick_json)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(provider, session_id) DO UPDATE SET
                quick_json = excluded.quick_json
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, sessionId, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 3, fileSize)
        sqlite3_bind_double(stmt, 4, mtime.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 5, jsonStr, -1, sqliteTransient)
        sqlite3_step(stmt)
    }

    /// Atomically replace full session stats, committed fingerprint, and FTS rows.
    func saveSessionStatsAndIndex(
        provider: ProviderKind,
        sessionId: String,
        fileSize: Int64,
        mtime: Date,
        stats: SessionStats,
        searchMessages: [SearchIndexMessage]
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let encoder = JSONEncoder()
        guard let json = try? encoder.encode(stats),
              let jsonStr = String(data: json, encoding: .utf8) else { return }

        execute("BEGIN TRANSACTION")
        defer {
            if sqlite3_get_autocommit(db) == 0 {
                execute("ROLLBACK")
            }
        }

        let upsertSQL = """
            INSERT INTO session_cache(provider, session_id, file_size, mtime, stats_json)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(provider, session_id) DO UPDATE SET
                file_size = excluded.file_size,
                mtime = excluded.mtime,
                stats_json = excluded.stats_json
        """
        var upsertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, upsertSQL, -1, &upsertStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(upsertStmt, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(upsertStmt, 2, sessionId, -1, sqliteTransient)
        sqlite3_bind_int64(upsertStmt, 3, fileSize)
        sqlite3_bind_double(upsertStmt, 4, mtime.timeIntervalSince1970)
        sqlite3_bind_text(upsertStmt, 5, jsonStr, -1, sqliteTransient)
        guard sqlite3_step(upsertStmt) == SQLITE_DONE else {
            sqlite3_finalize(upsertStmt)
            return
        }
        sqlite3_finalize(upsertStmt)

        let deleteSQL = "DELETE FROM messages WHERE provider = ? AND session_id = ?"
        var deleteStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(deleteStmt, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(deleteStmt, 2, sessionId, -1, sqliteTransient)
        guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
            sqlite3_finalize(deleteStmt)
            return
        }
        sqlite3_finalize(deleteStmt)

        if !searchMessages.isEmpty {
            let insertSQL = "INSERT INTO messages(provider, session_id, role, content, timestamp) VALUES(?, ?, ?, ?, ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else { return }

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            for message in searchMessages {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
                sqlite3_bind_text(stmt, 2, sessionId, -1, sqliteTransient)
                sqlite3_bind_text(stmt, 3, message.role, -1, sqliteTransient)
                sqlite3_bind_text(stmt, 4, message.content, -1, sqliteTransient)

                let timestamp = message.timestamp.map { isoFormatter.string(from: $0) } ?? ""
                sqlite3_bind_text(stmt, 5, timestamp, -1, sqliteTransient)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    sqlite3_finalize(stmt)
                    return
                }
            }
            sqlite3_finalize(stmt)
        }

        execute("COMMIT")
    }

    /// Remove cached data for deleted sessions
    func removeSessions(provider: ProviderKind, _ sessionIds: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        guard let db, !sessionIds.isEmpty else { return }

        execute("BEGIN TRANSACTION")
        for id in sessionIds {
            let sql1 = "DELETE FROM session_cache WHERE provider = ? AND session_id = ?"
            var stmt1: OpaquePointer?
            if sqlite3_prepare_v2(db, sql1, -1, &stmt1, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt1, 1, provider.rawValue, -1, sqliteTransient)
                sqlite3_bind_text(stmt1, 2, id, -1, sqliteTransient)
                sqlite3_step(stmt1)
                sqlite3_finalize(stmt1)
            }

            let sql2 = "DELETE FROM messages WHERE provider = ? AND session_id = ?"
            var stmt2: OpaquePointer?
            if sqlite3_prepare_v2(db, sql2, -1, &stmt2, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt2, 1, provider.rawValue, -1, sqliteTransient)
                sqlite3_bind_text(stmt2, 2, id, -1, sqliteTransient)
                sqlite3_step(stmt2)
                sqlite3_finalize(stmt2)
            }
        }
        execute("COMMIT")
    }

    // MARK: - Search Index

    /// Search results grouped by session
    struct SearchResult {
        let sessionId: String
        let snippet: String   // matched text with «» markers around highlights
        let role: String
    }

    /// Full-text search across all indexed messages. Returns best match per session.
    func search(query: String, provider: ProviderKind) -> [SearchResult] {
        lock.lock()
        defer { lock.unlock() }
        guard let db, !query.isEmpty else { return [] }

        // Sanitize query for FTS5: escape double quotes, wrap terms
        let sanitized = sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else { return [] }

        let sql = """
            SELECT session_id, snippet(messages, 3, '«', '»', '…', 20), role
            FROM messages
            WHERE provider = ? AND content MATCH ?
            ORDER BY rank
            LIMIT 200
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, sanitized, -1, sqliteTransient)

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

    private func sanitizeFTSQuery(_ raw: String) -> String {
        SearchUtils.ftsQuery(raw)
    }
}
