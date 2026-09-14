import Compression
import Foundation
import ClaudeStatisticsKit
import SQLite3

// MARK: - DatabaseService

final class DatabaseService {
    static let shared = DatabaseService()

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let databasePath: String?

    /// An explicit path allows isolated stores for regression/performance tests.
    /// Production callers share the application-support database.
    init(databasePath: String? = nil) {
        self.databasePath = databasePath
    }

    deinit { close() }

    // MARK: - Open / Close

    func open() {
        lock.lock()
        defer { lock.unlock() }
        guard db == nil else { return }

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("ClaudeStatistics")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = databasePath ?? dir.appendingPathComponent("data.db").path

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            print("[DatabaseService] Failed to open database: \(String(cString: sqlite3_errmsg(db!)))")
            db = nil
            return
        }

        // Performance pragmas
        execute("PRAGMA journal_mode = WAL")
        execute("PRAGMA synchronous = NORMAL")
        execute("PRAGMA foreign_keys = ON")

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

    func checkpoint() {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    func backupProviderSummary() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [:] }
        let sql = "SELECT provider, COUNT(*) FROM session_cache GROUP BY provider"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let provider = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            result[provider] = count
        }
        return result
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
                transcript_blob BLOB,
                project_path TEXT,
                cwd TEXT,
                metadata_json TEXT,
                parser_checkpoint BLOB,
                index_complete INTEGER NOT NULL DEFAULT 0,
                archive_state BLOB,
                PRIMARY KEY (provider, session_id)
            )
        """)
        execute("""
            CREATE TABLE IF NOT EXISTS session_index_keys(
                provider TEXT NOT NULL,
                session_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                fts_rowid INTEGER NOT NULL,
                PRIMARY KEY (provider, session_id, message_id),
                FOREIGN KEY (provider, session_id) REFERENCES session_cache(provider, session_id) ON DELETE CASCADE
            )
        """)
        execute(Self.transcriptSegmentsTableSQL)
        execute(Self.transcriptLegacyBlobsTableSQL)
    }

    /// Pre-v14 archives moved out of `session_cache` rows. `complete` precedes
    /// `blob` so testing it never walks the blob; only `complete = 1` rows are
    /// read, so a copy interrupted part-way is never mistaken for an archive.
    private static let transcriptLegacyBlobsTableSQL = """
        CREATE TABLE IF NOT EXISTS transcript_legacy_blobs(
            provider TEXT NOT NULL,
            session_id TEXT NOT NULL,
            complete INTEGER NOT NULL DEFAULT 0,
            blob BLOB NOT NULL,
            PRIMARY KEY (provider, session_id),
            FOREIGN KEY (provider, session_id) REFERENCES session_cache(provider, session_id) ON DELETE CASCADE
        )
    """

    /// Segmented transcript archive. Each row is at most
    /// `TranscriptArchiver.segmentSize` raw source bytes compressed on its own,
    /// so writing or appending an archive never holds the transcript. Only the
    /// committed generation below the committed offset (`archive_state`) is
    /// visible; any other row belongs to an interrupted or superseded pass.
    private static let transcriptSegmentsTableSQL = """
        CREATE TABLE IF NOT EXISTS transcript_segments(
            provider TEXT NOT NULL,
            session_id TEXT NOT NULL,
            generation INTEGER NOT NULL,
            source_offset INTEGER NOT NULL,
            raw_length INTEGER NOT NULL,
            blob BLOB NOT NULL,
            PRIMARY KEY (provider, session_id, generation, source_offset),
            FOREIGN KEY (provider, session_id) REFERENCES session_cache(provider, session_id) ON DELETE CASCADE
        )
    """

    /// Current schema version.
    /// v10 refreshes cached Codex quick titles after prompt-cleaning changes.
    /// v11 adds transcript_blob, project_path, cwd columns for session archival.
    /// v12 preserves provider metadata when a session becomes archived.
    /// v13 adds durable parser checkpoints and explicit index completeness.
    /// v14 adds the segmented transcript archive; v11 blobs stay readable and
    /// are replaced the next time their session is archived.
    /// v15 adds `transcript_legacy_blobs`; v11 blobs are moved there out of
    /// their rows in the background after startup, not during migration.
    private static let currentSchemaVersion: Int32 = 15
    private static let fullResetSchemaVersion: Int32 = 9
    private static let codexTitleCacheMigrationVersion: Int32 = 10
    private static let archivalColumnsVersion: Int32 = 11
    private static let sessionMetadataColumnVersion: Int32 = 12
    private static let parserCheckpointVersion: Int32 = 13
    private static let archiveSegmentsVersion: Int32 = 14
    private static let legacyBlobTableVersion: Int32 = 15

    private func migrateIfNeeded() {
        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            version = sqlite3_column_int(stmt, 0)
        }
        sqlite3_finalize(stmt)

        if version < Self.fullResetSchemaVersion {
            resetDatabase()
            version = Self.fullResetSchemaVersion
            execute("PRAGMA user_version = \(version)")
        }

        if version < Self.codexTitleCacheMigrationVersion {
            resetProviderCache(provider: .codex)
            version = Self.codexTitleCacheMigrationVersion
            execute("PRAGMA user_version = \(version)")
        }

        if version < Self.archivalColumnsVersion {
            addArchivalColumns()
            version = Self.archivalColumnsVersion
            execute("PRAGMA user_version = \(version)")
        }

        if version < Self.sessionMetadataColumnVersion {
            addSessionMetadataColumn()
            version = Self.sessionMetadataColumnVersion
            execute("PRAGMA user_version = \(version)")
        }

        if version < Self.parserCheckpointVersion {
            guard execute("BEGIN TRANSACTION") else { return }
            // Scan the old FTS table once, not once per cached session. Its
            // provider/session columns are UNINDEXED, so a correlated EXISTS
            // would turn this migration into O(sessions × messages).
            guard addSessionColumnIfMissing("parser_checkpoint", definition: "BLOB"),
                  addSessionColumnIfMissing("index_complete", definition: "INTEGER NOT NULL DEFAULT 0"),
                  execute("""
                    UPDATE session_cache SET index_complete = 1 WHERE (provider, session_id) IN (
                        SELECT DISTINCT provider, session_id FROM messages
                    )
                    """),
                  execute("PRAGMA user_version = \(Self.parserCheckpointVersion)"),
                  execute("COMMIT") else {
                execute("ROLLBACK")
                return
            }
            version = Self.parserCheckpointVersion
        }

        if version < Self.archiveSegmentsVersion {
            guard execute("BEGIN TRANSACTION") else { return }
            guard addSessionColumnIfMissing("archive_state", definition: "BLOB"),
                  execute(Self.transcriptSegmentsTableSQL),
                  execute("PRAGMA user_version = \(Self.archiveSegmentsVersion)"),
                  execute("COMMIT") else {
                execute("ROLLBACK")
                return
            }
            version = Self.archiveSegmentsVersion
        }

        if version < Self.legacyBlobTableVersion {
            guard execute(Self.transcriptLegacyBlobsTableSQL),
                  execute("PRAGMA user_version = \(Self.legacyBlobTableVersion)") else { return }
            version = Self.legacyBlobTableVersion
        }

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
        execute("DROP TABLE IF EXISTS transcript_legacy_blobs")
        execute("DROP TABLE IF EXISTS transcript_segments")
        execute("DROP TABLE IF EXISTS session_index_keys")
        execute("DROP TABLE IF EXISTS session_cache")
        createTables()
    }

    private func addArchivalColumns() {
        addSessionColumnIfMissing("transcript_blob", definition: "BLOB")
        addSessionColumnIfMissing("project_path", definition: "TEXT")
        addSessionColumnIfMissing("cwd", definition: "TEXT")
    }

    private func addSessionMetadataColumn() {
        addSessionColumnIfMissing("metadata_json", definition: "TEXT")
    }

    @discardableResult
    private func addSessionColumnIfMissing(_ name: String, definition: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM pragma_table_info('session_cache') WHERE name = ?", -1, &statement, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(statement, 1, name, -1, sqliteTransient)
        let exists = sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement)
        return exists || execute("ALTER TABLE session_cache ADD COLUMN \(name) \(definition)")
    }

    func resetProviderCache(provider: ProviderKind) {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        execute("BEGIN TRANSACTION")
        defer {
            if sqlite3_get_autocommit(db) == 0 {
                execute("ROLLBACK")
            }
        }

        let statements = [
            "DELETE FROM session_cache WHERE provider = ?",
            "DELETE FROM messages WHERE provider = ?"
        ]

        for sql in statements {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_finalize(stmt)
        }

        execute("COMMIT")
    }

    /// Invalidate derived parse data while preserving the session row,
    /// relationship metadata, and archived transcript blob. Used when a
    /// provider bumps `session.parserRevision` for live sessions.
    func invalidateSessionParseCaches(provider: ProviderKind, sessionIds: Set<String>) {
        guard !sessionIds.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let placeholders = Array(repeating: "?", count: sessionIds.count).joined(separator: ",")
        let statements = [
            "UPDATE session_cache SET quick_json = NULL, stats_json = NULL, parser_checkpoint = NULL, index_complete = 0 WHERE provider = ? AND session_id IN (\(placeholders))",
            "DELETE FROM session_index_keys WHERE provider = ? AND session_id IN (\(placeholders))",
            "DELETE FROM messages WHERE provider = ? AND session_id IN (\(placeholders))"
        ]

        execute("BEGIN TRANSACTION")
        var committed = false
        defer {
            if !committed, sqlite3_get_autocommit(db) == 0 {
                execute("ROLLBACK")
            }
        }

        for sql in statements {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
            var bindIndex: Int32 = 2
            for sessionId in sessionIds {
                sqlite3_bind_text(stmt, bindIndex, sessionId, -1, sqliteTransient)
                bindIndex += 1
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else { return }
        }

        execute("COMMIT")
        committed = true
    }

    /// Refresh provider-owned session metadata without forcing transcript or
    /// stats reparsing. This also backfills relationship metadata for cache
    /// rows created before the metadata column existed. Rows whose metadata is
    /// unchanged are left alone: on a clone of a real database, rewriting every
    /// Codex row on each forced rescan wrote 1.91 GB of WAL.
    func saveSessionMetadata(provider: ProviderKind, sessions: [Session]) {
        let sessionsWithMetadata = sessions.filter { !$0.metadata.isEmpty }
        guard !sessionsWithMetadata.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let sql = """
            INSERT INTO session_cache(provider, session_id, file_size, mtime, metadata_json)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(provider, session_id) DO UPDATE SET
                metadata_json = excluded.metadata_json
            WHERE session_cache.metadata_json IS NOT excluded.metadata_json
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let encoder = JSONEncoder()
        execute("BEGIN TRANSACTION")
        var committed = false
        defer {
            if !committed, sqlite3_get_autocommit(db) == 0 {
                execute("ROLLBACK")
            }
        }

        for session in sessionsWithMetadata {
            guard let data = try? encoder.encode(session.metadata),
                  let json = String(data: data, encoding: .utf8) else { continue }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, session.id, -1, sqliteTransient)
            sqlite3_bind_int64(stmt, 3, session.fileSize)
            sqlite3_bind_double(stmt, 4, session.lastModified.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 5, json, -1, sqliteTransient)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return }
        }

        execute("COMMIT")
        committed = true
    }

    // MARK: - Stats Cache

    struct CachedSession {
        let provider: ProviderKind
        let sessionId: String
        let fileSize: Int64
        let mtime: Date
        let quickStats: SessionQuickStats?
        let sessionStats: SessionStats?
        let projectPath: String?
        let cwd: String?
        let hasTranscript: Bool
        let metadata: [String: String]
    }

    /// Load all cached sessions from the database
    func loadAllCached(provider: ProviderKind) -> [String: CachedSession] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [:] }

        let sql = """
            SELECT session_id, file_size, mtime, quick_json, stats_json,
                   project_path, cwd, (transcript_blob IS NOT NULL OR archive_state IS NOT NULL OR EXISTS (
                       SELECT 1 FROM transcript_legacy_blobs legacy
                       WHERE legacy.provider = session_cache.provider
                         AND legacy.session_id = session_cache.session_id AND legacy.complete = 1)), metadata_json
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

            var projectPath: String?
            if let ptr = sqlite3_column_text(stmt, 5) {
                projectPath = String(cString: ptr)
            }

            var cwd: String?
            if let ptr = sqlite3_column_text(stmt, 6) {
                cwd = String(cString: ptr)
            }

            let hasTranscript = sqlite3_column_int(stmt, 7) != 0
            var metadata: [String: String] = [:]
            if let ptr = sqlite3_column_text(stmt, 8) {
                let json = Data(String(cString: ptr).utf8)
                metadata = (try? decoder.decode([String: String].self, from: json)) ?? [:]
            }

            result[sessionId] = CachedSession(
                provider: provider,
                sessionId: sessionId,
                fileSize: fileSize,
                mtime: mtime,
                quickStats: quick,
                sessionStats: stats,
                projectPath: projectPath,
                cwd: cwd,
                hasTranscript: hasTranscript,
                metadata: metadata
            )
        }

        return result
    }

    /// Lightweight fingerprint of a cached session — `(fileSize, mtime,
    /// hasStats)` —used by `processDirtyIds` to decide which sessions need
    /// reparsing without paying the JSON-decode cost for all 270+ entries.
    struct SessionFingerprint {
        let fileSize: Int64
        let mtime: Date
        let hasStats: Bool
    }

    /// Return per-session `(fileSize, mtime, hasStats)` for every cached row
    /// without decoding the JSON bodies. ~10× cheaper than `loadAllCached`
    /// when caller only needs the staleness check.
    func loadCacheFingerprints(provider: ProviderKind) -> [String: SessionFingerprint] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [:] }

        let sql = """
            SELECT session_id, file_size, mtime, stats_json IS NOT NULL
            FROM session_cache
            WHERE provider = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)

        var result: [String: SessionFingerprint] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionId = String(cString: sqlite3_column_text(stmt, 0))
            let fileSize = sqlite3_column_int64(stmt, 1)
            let mtime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let hasStats = sqlite3_column_int(stmt, 3) != 0
            result[sessionId] = SessionFingerprint(fileSize: fileSize, mtime: mtime, hasStats: hasStats)
        }
        return result
    }

    /// Whether a session's cache fingerprint is stale relative to the on-disk
    /// file. Same semantics as `needsReparse(_:cache:)` but takes a
    /// fingerprint dictionary instead of fully decoded `CachedSession`s.
    func needsReparse(sessionId: String, fileSize: Int64, mtime: Date, fingerprints: [String: SessionFingerprint]) -> Bool {
        guard let fp = fingerprints[sessionId] else { return true }
        if !fp.hasStats { return true }
        return fp.fileSize != fileSize ||
               abs(fp.mtime.timeIntervalSince(mtime)) > 1.0
    }

    /// Load cache only for the given session ids. Used on the dirty-event fast
    /// path to avoid the O(N) JSON decode of every cached session when only a
    /// handful of files actually changed.
    func loadCached(provider: ProviderKind, sessionIds: Set<String>) -> [String: CachedSession] {
        guard !sessionIds.isEmpty else { return [:] }
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [:] }

        let placeholders = Array(repeating: "?", count: sessionIds.count).joined(separator: ",")
        let sql = """
            SELECT session_id, file_size, mtime, quick_json, stats_json,
                   project_path, cwd, (transcript_blob IS NOT NULL OR archive_state IS NOT NULL OR EXISTS (
                       SELECT 1 FROM transcript_legacy_blobs legacy
                       WHERE legacy.provider = session_cache.provider
                         AND legacy.session_id = session_cache.session_id AND legacy.complete = 1)), metadata_json
            FROM session_cache
            WHERE provider = ? AND session_id IN (\(placeholders))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
        var bindIndex: Int32 = 2
        for sessionId in sessionIds {
            sqlite3_bind_text(stmt, bindIndex, sessionId, -1, sqliteTransient)
            bindIndex += 1
        }

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

            var projectPath: String?
            if let ptr = sqlite3_column_text(stmt, 5) {
                projectPath = String(cString: ptr)
            }

            var cwd: String?
            if let ptr = sqlite3_column_text(stmt, 6) {
                cwd = String(cString: ptr)
            }

            let hasTranscript = sqlite3_column_int(stmt, 7) != 0
            var metadata: [String: String] = [:]
            if let ptr = sqlite3_column_text(stmt, 8) {
                let json = Data(String(cString: ptr).utf8)
                metadata = (try? decoder.decode([String: String].self, from: json)) ?? [:]
            }

            result[sessionId] = CachedSession(
                provider: provider,
                sessionId: sessionId,
                fileSize: fileSize,
                mtime: mtime,
                quickStats: quick,
                sessionStats: stats,
                projectPath: projectPath,
                cwd: cwd,
                hasTranscript: hasTranscript,
                metadata: metadata
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

    /// One session's slice of `saveSessionsStatsAndIndexes`. Public so
    /// callers can build up a batch in their own scope (e.g. the parse
    /// pipeline that emits N results from one task group).
    typealias SearchIndexUpdate = SessionSearchIndexUpdate

    enum CheckpointExpectation {
        case any
        case matches(UUID?)
    }

    struct SaveSessionStatsRequest {
        let sessionId: String
        let fileSize: Int64
        let mtime: Date
        let stats: SessionStats
        let searchIndexUpdate: SearchIndexUpdate
        let checkpoint: SessionParseCheckpoint?
        let expectedCheckpoint: CheckpointExpectation
        let quickStats: SessionQuickStats?

        init(sessionId: String, fileSize: Int64, mtime: Date, stats: SessionStats,
             searchIndexUpdate: SearchIndexUpdate, checkpoint: SessionParseCheckpoint? = nil,
             expectedCheckpoint: CheckpointExpectation = .any, quickStats: SessionQuickStats? = nil) {
            self.sessionId = sessionId
            self.fileSize = fileSize
            self.mtime = mtime
            self.stats = stats
            self.searchIndexUpdate = searchIndexUpdate
            self.checkpoint = checkpoint
            self.expectedCheckpoint = expectedCheckpoint
            self.quickStats = quickStats
        }

        init(sessionId: String, fileSize: Int64, mtime: Date, stats: SessionStats,
             searchMessages: [SearchIndexMessage]) {
            self.init(sessionId: sessionId, fileSize: fileSize, mtime: mtime,
                      stats: stats, searchIndexUpdate: .replace(searchMessages))
        }
    }

    /// Atomically replace full session stats, committed fingerprint, and
    /// FTS rows. Single-session convenience wrapper around the batch
    /// API.
    func saveSessionStatsAndIndex(
        provider: ProviderKind,
        sessionId: String,
        fileSize: Int64,
        mtime: Date,
        stats: SessionStats,
        searchMessages: [SearchIndexMessage]
    ) {
        saveSessionsStatsAndIndexes(
            provider: provider,
            requests: [SaveSessionStatsRequest(
                sessionId: sessionId,
                fileSize: fileSize,
                mtime: mtime,
                stats: stats,
                searchMessages: searchMessages
            )]
        )
    }

    /// PR5: write N sessions' stats + FTS rows under a single
    /// transaction with prepared statements reused across the loop.
    /// Replaces the per-session `BEGIN / prepare / step / finalize /
    /// COMMIT` cycle that dominated forced-rescan time.
    @discardableResult
    func saveSessionsStatsAndIndexes(
        provider: ProviderKind,
        requests: [SaveSessionStatsRequest]
    ) -> Bool {
        guard !requests.isEmpty else { return true }
        let signpostState = PerformanceTracer.begin("DatabaseService.saveSessionStatsAndIndex")
        defer { PerformanceTracer.end("DatabaseService.saveSessionStatsAndIndex", signpostState) }
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return false }

        let encoder = JSONEncoder()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // Every refusal is logged: the store turns `false` into a silent retry.
        func fail(_ step: String, _ sessionId: String? = nil, error: Error? = nil) -> Bool {
            let detail = error.map { String(describing: $0) } ?? String(cString: sqlite3_errmsg(db))
            DiagnosticLogger.shared.warning(
                "saveSessionsStatsAndIndexes(\(provider.rawValue)\(sessionId.map { " " + $0 } ?? "")) failed at \(step): \(detail)"
            )
            return false
        }
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else { return fail("begin") }
        var committed = false
        defer {
            if !committed, sqlite3_get_autocommit(db) == 0 {
                execute("ROLLBACK")
            }
        }

        let upsertSQL = """
            INSERT INTO session_cache(provider, session_id, file_size, mtime, stats_json, parser_checkpoint, index_complete, quick_json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, session_id) DO UPDATE SET
                file_size = excluded.file_size,
                mtime = excluded.mtime,
                stats_json = excluded.stats_json,
                parser_checkpoint = excluded.parser_checkpoint,
                index_complete = CASE WHEN excluded.index_complete = 1 THEN 1
                    WHEN session_cache.file_size != excluded.file_size OR session_cache.mtime != excluded.mtime THEN 0
                    ELSE session_cache.index_complete END,
                quick_json = COALESCE(excluded.quick_json, session_cache.quick_json)
        """
        let deleteSQL = "DELETE FROM messages WHERE provider = ? AND session_id = ?"
        let insertSQL = "INSERT INTO messages(provider, session_id, role, content, timestamp) VALUES(?, ?, ?, ?, ?)"

        var upsertStmt: OpaquePointer?
        var deleteStmt: OpaquePointer?
        var insertStmt: OpaquePointer?
        var keyInsertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, upsertSQL, -1, &upsertStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "INSERT INTO session_index_keys(provider, session_id, message_id, fts_rowid) VALUES(?, ?, ?, ?)", -1, &keyInsertStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(upsertStmt)
            sqlite3_finalize(deleteStmt)
            sqlite3_finalize(insertStmt)
            sqlite3_finalize(keyInsertStmt)
            return fail("prepare")
        }
        defer {
            sqlite3_finalize(upsertStmt)
            sqlite3_finalize(deleteStmt)
            sqlite3_finalize(insertStmt)
            sqlite3_finalize(keyInsertStmt)
        }

        for request in requests {
            if case .matches(let expected) = request.expectedCheckpoint {
                let stored = loadParseCheckpointID(provider: provider, sessionId: request.sessionId)
                guard stored == expected else {
                    DiagnosticLogger.shared.warning(
                        "Checkpoint of \(provider.rawValue) session \(request.sessionId) changed under its parse " +
                        "(expected \(expected?.uuidString ?? "none"), stored \(stored?.uuidString ?? "none")); not committing"
                    )
                    return false
                }
            }
            let json: Data
            do { json = try encoder.encode(request.stats) } catch { return fail("stats json", request.sessionId, error: error) }
            guard let jsonStr = String(data: json, encoding: .utf8) else { return fail("stats utf8", request.sessionId) }

            let checkpointData: Data?
            let quickData: Data?
            do {
                checkpointData = try request.checkpoint.map { try ParseCheckpointCoding.encode($0) }
                quickData = try request.quickStats.map { try encoder.encode($0) }
            } catch { return fail("checkpoint/quick encoding", request.sessionId, error: error) }

            sqlite3_reset(upsertStmt)
            sqlite3_clear_bindings(upsertStmt)
            sqlite3_bind_text(upsertStmt, 1, provider.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(upsertStmt, 2, request.sessionId, -1, sqliteTransient)
            sqlite3_bind_int64(upsertStmt, 3, request.fileSize)
            sqlite3_bind_double(upsertStmt, 4, request.mtime.timeIntervalSince1970)
            sqlite3_bind_text(upsertStmt, 5, jsonStr, -1, sqliteTransient)
            if let checkpointData {
                _ = checkpointData.withUnsafeBytes { sqlite3_bind_blob(upsertStmt, 6, $0.baseAddress, Int32($0.count), sqliteTransient) }
            } else { sqlite3_bind_null(upsertStmt, 6) }
            let completeIndex: Bool
            if case .preserve = request.searchIndexUpdate { completeIndex = false } else { completeIndex = true }
            sqlite3_bind_int(upsertStmt, 7, completeIndex ? 1 : 0)
            if let quickData, let quickJSON = String(data: quickData, encoding: .utf8) {
                sqlite3_bind_text(upsertStmt, 8, quickJSON, -1, sqliteTransient)
            } else { sqlite3_bind_null(upsertStmt, 8) }
            guard sqlite3_step(upsertStmt) == SQLITE_DONE else { return fail("upsert", request.sessionId) }

            let rows: [(String?, SearchIndexMessage)]
            switch request.searchIndexUpdate {
            case .preserve: continue
            case .replace(let messages): rows = messages.map { (nil, $0) }
            case .replaceIdentified(let messages):
                // Transcripts can hold the same record twice (Claude replays a
                // message, tool call and all, when a session resumes); one key
                // per ID, like `.update` below, or the unique index refuses
                // the whole commit and the session retries forever.
                rows = Self.lastOccurrences(of: messages)
            case .update(let messages, let removing):
                let ids = Set(removing).union(messages.map(\.id))
                guard deleteIdentifiedIndexRows(provider: provider, sessionId: request.sessionId, ids: Array(ids)) else {
                    return fail("index update delete", request.sessionId)
                }
                rows = Self.lastOccurrences(of: messages)
            }

            if case .update = request.searchIndexUpdate {
                // Only the affected stable IDs were removed above.
            } else {
                sqlite3_reset(deleteStmt)
                sqlite3_clear_bindings(deleteStmt)
                sqlite3_bind_text(deleteStmt, 1, provider.rawValue, -1, sqliteTransient)
                sqlite3_bind_text(deleteStmt, 2, request.sessionId, -1, sqliteTransient)
                guard sqlite3_step(deleteStmt) == SQLITE_DONE else { return fail("index delete", request.sessionId) }
                guard deleteIdentifiedIndexRows(provider: provider, sessionId: request.sessionId, ids: nil) else {
                    return fail("index key delete", request.sessionId)
                }
            }

            for (id, message) in rows {
                sqlite3_reset(insertStmt)
                sqlite3_clear_bindings(insertStmt)
                sqlite3_bind_text(insertStmt, 1, provider.rawValue, -1, sqliteTransient)
                sqlite3_bind_text(insertStmt, 2, request.sessionId, -1, sqliteTransient)
                sqlite3_bind_text(insertStmt, 3, message.role, -1, sqliteTransient)
                sqlite3_bind_text(insertStmt, 4, message.content, -1, sqliteTransient)

                let timestamp = message.timestamp.map { isoFormatter.string(from: $0) } ?? ""
                sqlite3_bind_text(insertStmt, 5, timestamp, -1, sqliteTransient)
                guard sqlite3_step(insertStmt) == SQLITE_DONE else { return fail("index insert", request.sessionId) }
                if let id {
                    let rowID = sqlite3_last_insert_rowid(db)
                    sqlite3_reset(keyInsertStmt)
                    sqlite3_clear_bindings(keyInsertStmt)
                    sqlite3_bind_text(keyInsertStmt, 1, provider.rawValue, -1, sqliteTransient)
                    sqlite3_bind_text(keyInsertStmt, 2, request.sessionId, -1, sqliteTransient)
                    sqlite3_bind_text(keyInsertStmt, 3, id, -1, sqliteTransient)
                    sqlite3_bind_int64(keyInsertStmt, 4, rowID)
                    guard sqlite3_step(keyInsertStmt) == SQLITE_DONE else { return fail("index key insert", request.sessionId) }
                }
            }
        }

        committed = sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
        return committed || fail("commit")
    }

    /// Identified index rows with one entry per ID — its last occurrence, in order.
    static func lastOccurrences(of messages: [IdentifiedSearchIndexMessage]) -> [(String?, SearchIndexMessage)] {
        let lastIndices = Dictionary(messages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, last in last })
        return messages.enumerated().compactMap { index, value in
            lastIndices[value.id] == index ? (value.id, value.message) : nil
        }
    }

    func loadParseCheckpoint(provider: ProviderKind, sessionId: String) -> SessionParseCheckpoint? {
        parserCheckpointBlob(provider: provider, sessionId: sessionId).flatMap(ParseCheckpointCoding.decode)
    }

    /// The stored checkpoint's ID alone — all a commit's compare-and-swap needs —
    /// without materializing its state.
    func loadParseCheckpointID(provider: ProviderKind, sessionId: String) -> UUID? {
        parserCheckpointBlob(provider: provider, sessionId: sessionId).flatMap(ParseCheckpointCoding.decodeID)
    }

    private func parserCheckpointBlob(provider: ProviderKind, sessionId: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT parser_checkpoint FROM session_cache WHERE provider = ? AND session_id = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, sessionId, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    func sessionsWithCompleteIndex(provider: ProviderKind) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT session_id FROM session_cache WHERE provider = ? AND index_complete = 1", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, provider.rawValue, -1, sqliteTransient)
        var ids: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { ids.insert(String(cString: value)) }
        }
        return ids
    }

    func hasCompleteIndex(provider: ProviderKind, sessionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT index_complete FROM session_cache WHERE provider = ? AND session_id = ?", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, sessionId, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
    }

    private func deleteIdentifiedIndexRows(provider: ProviderKind, sessionId: String, ids: [String]?) -> Bool {
        guard let db else { return false }
        let condition = "provider = ? AND session_id = ?" + (ids == nil ? "" : " AND message_id = ?")
        let statements = [
            "DELETE FROM messages WHERE rowid IN (SELECT fts_rowid FROM session_index_keys WHERE \(condition))",
            "DELETE FROM session_index_keys WHERE \(condition)"
        ]
        for sql in statements {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(statement) }
            for id in ids ?? [""] {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, provider.rawValue, -1, sqliteTransient)
                sqlite3_bind_text(statement, 2, sessionId, -1, sqliteTransient)
                if ids != nil { sqlite3_bind_text(statement, 3, id, -1, sqliteTransient) }
                guard sqlite3_step(statement) == SQLITE_DONE else { return false }
            }
        }
        return true
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

    // MARK: - Transcript Archival

    func transcriptArchiveState(provider: ProviderKind, sessionId: String) -> TranscriptArchiveState? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        let sql = "SELECT archive_state FROM session_cache WHERE provider = ? AND session_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, sessionId, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) == SQLITE_BLOB,
              let pointer = sqlite3_column_blob(stmt, 0) else { return nil }
        let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, 0)))
        return try? JSONDecoder().decode(TranscriptArchiveState.self, from: data)
    }

    func discardUncommittedTranscriptSegments(provider: ProviderKind, sessionId: String,
                                              committed: TranscriptArchiveState?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return false }
        let sql = committed == nil
            ? "DELETE FROM transcript_segments WHERE provider = ? AND session_id = ?"
            : "DELETE FROM transcript_segments WHERE provider = ? AND session_id = ? AND (generation <> ? OR source_offset >= ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, sessionId, -1, sqliteTransient)
        if let committed {
            sqlite3_bind_int64(stmt, 3, committed.generation)
            sqlite3_bind_int64(stmt, 4, committed.source.offset)
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func insertTranscriptSegment(provider: ProviderKind, sessionId: String, generation: Int64,
                                 sourceOffset: Int64, rawLength: Int64, compressed: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db, !compressed.isEmpty else { return false }
        let sql = """
            INSERT OR REPLACE INTO transcript_segments(provider, session_id, generation, source_offset, raw_length, blob)
            VALUES(?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, sessionId, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 3, generation)
        sqlite3_bind_int64(stmt, 4, sourceOffset)
        sqlite3_bind_int64(stmt, 5, rawLength)
        compressed.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(stmt, 6, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Publish a completed pass in one small transaction: the new state, the
    /// session fields the archive has always carried (so the session can still
    /// be listed once its file is deleted), and removal of everything the new
    /// state supersedes — other generations and any pre-v14 blob.
    func commitTranscriptArchive(provider: ProviderKind, sessionId: String, state: TranscriptArchiveState,
                                 projectPath: String, cwd: String?, metadata: [String: String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db, let stateData = try? JSONEncoder().encode(state) else { return false }
        guard execute("BEGIN TRANSACTION") else { return false }
        var committed = false
        defer {
            if !committed, sqlite3_get_autocommit(db) == 0 {
                execute("ROLLBACK")
            }
        }

        var update: OpaquePointer?
        let updateSQL = """
            UPDATE session_cache
            SET archive_state = ?, transcript_blob = NULL, project_path = ?, cwd = ?, metadata_json = ?
            WHERE provider = ? AND session_id = ?
        """
        guard sqlite3_prepare_v2(db, updateSQL, -1, &update, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(update) }
        stateData.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(update, 1, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
        sqlite3_bind_text(update, 2, projectPath, -1, sqliteTransient)
        if let cwd {
            sqlite3_bind_text(update, 3, cwd, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(update, 3)
        }
        if let data = try? JSONEncoder().encode(metadata),
           let json = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(update, 4, json, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(update, 4)
        }
        sqlite3_bind_text(update, 5, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(update, 6, sessionId, -1, sqliteTransient)
        guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(db) == 1 else { return false }

        var prune: OpaquePointer?
        let pruneSQL = "DELETE FROM transcript_segments WHERE provider = ? AND session_id = ? AND generation <> ?"
        guard sqlite3_prepare_v2(db, pruneSQL, -1, &prune, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(prune) }
        sqlite3_bind_text(prune, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(prune, 2, sessionId, -1, sqliteTransient)
        sqlite3_bind_int64(prune, 3, state.generation)
        guard sqlite3_step(prune) == SQLITE_DONE else { return false }

        // A relocated pre-v14 archive is superseded as well.
        var dropLegacy: OpaquePointer?
        let dropSQL = "DELETE FROM transcript_legacy_blobs WHERE provider = ? AND session_id = ?"
        guard sqlite3_prepare_v2(db, dropSQL, -1, &dropLegacy, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(dropLegacy) }
        sqlite3_bind_text(dropLegacy, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(dropLegacy, 2, sessionId, -1, sqliteTransient)
        guard sqlite3_step(dropLegacy) == SQLITE_DONE, execute("COMMIT") else { return false }
        committed = true
        return true
    }

    /// The archived transcript, decompressed. A segmented archive is rebuilt
    /// one segment at a time — each read holds the lock only for its own row —
    /// and rejected if a gap, short segment or corrupt blob would make it
    /// differ from the bytes its state recorded. Pre-v14 archives are one blob.
    /// The result is whole: readers of an archived transcript are not bounded.
    /// Writes an archived transcript to `url` one stored piece at a time:
    /// segments are decompressed one by one, and a pre-v14 single blob is read
    /// `chunkBytes` at a time and inflated as a stream. Memory stays at about
    /// one piece whatever the transcript's size. False, with no file left at
    /// `url`, when nothing complete is stored or a piece does not decode.
    func writeArchivedTranscript(provider: ProviderKind, sessionId: String, to url: URL,
                                 chunkBytes: Int = DatabaseService.legacyRelocationChunkBytes) -> Bool {
        precondition(chunkBytes > 0)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return false }
        let written: Bool
        if let state = transcriptArchiveState(provider: provider, sessionId: sessionId) {
            written = writeArchiveSegments(provider: provider, sessionId: sessionId, state: state, to: handle)
        } else if let blob = legacyArchiveBlob(provider: provider, sessionId: sessionId) {
            written = inflateLegacyArchive(blob, chunkBytes: chunkBytes, to: handle)
        } else {
            written = false
        }
        let closed = (try? handle.close()) != nil
        guard written, closed else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    private func writeArchiveSegments(provider: ProviderKind, sessionId: String,
                                      state: TranscriptArchiveState, to handle: FileHandle) -> Bool {
        var expected: Int64 = 0
        for (offset, length) in transcriptSegmentLayout(provider: provider, sessionId: sessionId, state: state) {
            guard !Task.isCancelled, offset == expected,
                  let blob = transcriptSegmentBlob(provider: provider, sessionId: sessionId,
                                                   generation: state.generation, sourceOffset: offset) else { return false }
            let written: Bool = autoreleasepool {
                guard let raw = (try? (blob as NSData).decompressed(using: .zlib)) as Data?,
                      raw.count == length else { return false }
                return (try? handle.write(contentsOf: raw)) != nil
            }
            guard written else { return false }
            expected += length
        }
        return expected == state.source.offset
    }

    private struct LegacyArchiveBlob {
        let table: String
        let column: String
        let row: Int64
        let length: Int64
    }

    /// A complete pre-v14 archive: the relocated copy, else the one still inline.
    private func legacyArchiveBlob(provider: ProviderKind, sessionId: String) -> LegacyArchiveBlob? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        let candidates = [
            ("transcript_legacy_blobs", "blob", "complete = 1"),
            ("session_cache", "transcript_blob", "transcript_blob IS NOT NULL"),
        ]
        for (table, column, condition) in candidates {
            let sql = """
                SELECT rowid, length(\(column)) FROM \(table)
                WHERE provider = ? AND session_id = ? AND \(condition) AND typeof(\(column)) = 'blob'
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, sessionId, -1, sqliteTransient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { continue }
            let length = sqlite3_column_int64(stmt, 1)
            // Incremental blob offsets are 32-bit.
            guard length > 0, length <= Int64(Int32.max) else { continue }
            return LegacyArchiveBlob(table: table, column: column, row: sqlite3_column_int64(stmt, 0), length: length)
        }
        return nil
    }

    /// Raw DEFLATE (what `NSData.compressed(using: .zlib)` wrote), inflated as
    /// the blob is read, into a fixed 1 MiB output buffer.
    private func inflateLegacyArchive(_ blob: LegacyArchiveBlob, chunkBytes: Int, to handle: FileHandle) -> Bool {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return false
        }
        defer { compression_stream_destroy(stream) }
        let inputCapacity = Int(min(Int64(chunkBytes), blob.length))
        let outputCapacity = 1 << 20
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)
        defer {
            input.deallocate()
            output.deallocate()
        }
        stream.pointee.src_ptr = UnsafePointer(input)
        stream.pointee.src_size = 0
        var offset: Int64 = 0
        while true {
            if stream.pointee.src_size == 0, offset < blob.length {
                guard !Task.isCancelled else { return false }
                let count = Int(min(Int64(inputCapacity), blob.length - offset))
                guard readLegacyChunk(blob, offset: offset, count: count, into: input) else { return false }
                stream.pointee.src_ptr = UnsafePointer(input)
                stream.pointee.src_size = count
                offset += Int64(count)
            }
            let finalize = offset == blob.length
            stream.pointee.dst_ptr = output
            stream.pointee.dst_size = outputCapacity
            let status = compression_stream_process(stream, finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
            let produced = outputCapacity - stream.pointee.dst_size
            if produced > 0 {
                let bytes = Data(bytesNoCopy: output, count: produced, deallocator: .none)
                guard (try? handle.write(contentsOf: bytes)) != nil else { return false }
            }
            switch status {
            case COMPRESSION_STATUS_END:
                return true
            case COMPRESSION_STATUS_OK:
                // Every byte consumed and nothing more produced, yet not ended: truncated.
                if finalize, produced == 0, stream.pointee.src_size == 0 { return false }
            default:
                return false
            }
        }
    }

    /// One read, under the lock; a blob that changed size underneath fails it.
    private func readLegacyChunk(_ blob: LegacyArchiveBlob, offset: Int64, count: Int,
                                 into buffer: UnsafeMutablePointer<UInt8>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return false }
        var handle: OpaquePointer?
        defer { sqlite3_blob_close(handle) }
        return sqlite3_blob_open(db, "main", blob.table, blob.column, blob.row, 0, &handle) == SQLITE_OK &&
            Int64(sqlite3_blob_bytes(handle)) == blob.length &&
            sqlite3_blob_read(handle, buffer, Int32(count), Int32(offset)) == SQLITE_OK
    }

    private func transcriptSegmentLayout(provider: ProviderKind, sessionId: String,
                                         state: TranscriptArchiveState) -> [(offset: Int64, length: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let sql = """
            SELECT source_offset, raw_length FROM transcript_segments
            WHERE provider = ? AND session_id = ? AND generation = ? AND source_offset < ?
            ORDER BY source_offset
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, sessionId, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 3, state.generation)
        sqlite3_bind_int64(stmt, 4, state.source.offset)
        var layout: [(offset: Int64, length: Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            layout.append((sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1)))
        }
        return layout
    }

    private func transcriptSegmentBlob(provider: ProviderKind, sessionId: String,
                                       generation: Int64, sourceOffset: Int64) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }
        let sql = """
            SELECT blob FROM transcript_segments
            WHERE provider = ? AND session_id = ? AND generation = ? AND source_offset = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, sessionId, -1, sqliteTransient)
        sqlite3_bind_int64(stmt, 3, generation)
        sqlite3_bind_int64(stmt, 4, sourceOffset)
        guard sqlite3_step(stmt) == SQLITE_ROW, let pointer = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    /// The raw pre-v14 archive blob: its relocated copy if the move finished,
    /// otherwise the one still inside the session row.
    func loadTranscript(provider: ProviderKind, sessionId: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }

        let queries = [
            "SELECT blob FROM transcript_legacy_blobs WHERE provider = ? AND session_id = ? AND complete = 1",
            "SELECT transcript_blob FROM session_cache WHERE provider = ? AND session_id = ?",
        ]
        for sql in queries {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
            sqlite3_bind_text(stmt, 2, sessionId, -1, sqliteTransient)
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) == SQLITE_BLOB else { continue }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            guard count > 0, let pointer = sqlite3_column_blob(stmt, 0) else { continue }
            return Data(bytes: pointer, count: count)
        }
        return nil
    }

    // MARK: - Pre-v14 archives stored inline

    /// Size of one copy step when moving a pre-v14 archive out of its row. The
    /// database lock is held for one step at a time, never for a whole blob.
    static let legacyRelocationChunkBytes = 8 * 1024 * 1024

    /// Sessions whose pre-v14 archive still sits inside their `session_cache`
    /// row, smallest first. Neither the null test nor `length()` reads the blob.
    func sessionsWithInlineLegacyTranscripts(provider: ProviderKind) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return [] }
        let sql = """
            SELECT session_id FROM session_cache
            WHERE provider = ? AND transcript_blob IS NOT NULL
            ORDER BY length(transcript_blob)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) {
            ids.append(String(cString: text))
        }
        return ids
    }

    /// Drop copies an interrupted relocation left half-written. Readers never
    /// see them; this only reclaims their pages.
    @discardableResult
    func discardIncompleteLegacyRelocations(provider: ProviderKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return false }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM transcript_legacy_blobs WHERE provider = ? AND complete = 0"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Move one session's pre-v14 archive out of its `session_cache` row.
    ///
    /// Inline, the blob sits before `metadata_json`, `parser_checkpoint`,
    /// `index_complete` and `archive_state`, so every read or update of those
    /// columns walks its whole overflow chain — 1.06 s per read, 1.23 s per
    /// one-column update, for a real 526 MB archive. The copy goes through
    /// SQLite's incremental blob I/O a chunk at a time, so neither this process
    /// nor SQLite holds the whole blob, and the lock is released between
    /// chunks. The copy becomes visible and the inline one is dropped in one
    /// final transaction; until then readers keep using the inline blob.
    func relocateInlineLegacyTranscript(provider: ProviderKind, sessionId: String,
                                        chunkBytes: Int = DatabaseService.legacyRelocationChunkBytes) -> Bool {
        precondition(chunkBytes > 0)
        guard let (sourceRow, length) = prepareLegacyRelocation(provider: provider, sessionId: sessionId) else {
            return false
        }
        var buffer = [UInt8](repeating: 0, count: Int(min(Int64(chunkBytes), length)))
        var offset: Int64 = 0
        while offset < length {
            if Task.isCancelled { return false }
            let count = Int(min(Int64(buffer.count), length - offset))
            guard copyLegacyChunk(provider: provider, sessionId: sessionId, sourceRow: sourceRow,
                                  offset: offset, count: count, buffer: &buffer) else { return false }
            offset += Int64(count)
        }
        return finishLegacyRelocation(provider: provider, sessionId: sessionId,
                                      sourceRow: sourceRow, length: length)
    }

    /// Reserve an invisible, correctly sized destination row.
    private func prepareLegacyRelocation(provider: ProviderKind, sessionId: String) -> (Int64, Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }

        var find: OpaquePointer?
        let findSQL = """
            SELECT rowid, length(transcript_blob) FROM session_cache
            WHERE provider = ? AND session_id = ? AND transcript_blob IS NOT NULL
        """
        guard sqlite3_prepare_v2(db, findSQL, -1, &find, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(find, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(find, 2, sessionId, -1, sqliteTransient)
        guard sqlite3_step(find) == SQLITE_ROW else { sqlite3_finalize(find); return nil }
        let row = sqlite3_column_int64(find, 0)
        let length = sqlite3_column_int64(find, 1)
        sqlite3_finalize(find)
        // Incremental blob offsets are 32-bit.
        guard length > 0, length <= Int64(Int32.max) else { return nil }

        var insert: OpaquePointer?
        let insertSQL = """
            INSERT OR REPLACE INTO transcript_legacy_blobs(provider, session_id, complete, blob)
            VALUES(?, ?, 0, zeroblob(?))
        """
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insert, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(insert) }
        sqlite3_bind_text(insert, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(insert, 2, sessionId, -1, sqliteTransient)
        sqlite3_bind_int64(insert, 3, length)
        guard sqlite3_step(insert) == SQLITE_DONE else { return nil }
        return (row, length)
    }

    /// Copy one chunk. Closing the read-write blob handle in autocommit mode
    /// commits the write, so each chunk is its own short transaction.
    private func copyLegacyChunk(provider: ProviderKind, sessionId: String, sourceRow: Int64,
                                 offset: Int64, count: Int, buffer: inout [UInt8]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return false }

        var find: OpaquePointer?
        let findSQL = "SELECT rowid FROM transcript_legacy_blobs WHERE provider = ? AND session_id = ? AND complete = 0"
        guard sqlite3_prepare_v2(db, findSQL, -1, &find, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(find, 1, provider.rawValue, -1, sqliteTransient)
        sqlite3_bind_text(find, 2, sessionId, -1, sqliteTransient)
        // An archive commit in the meantime removes the destination: stop.
        guard sqlite3_step(find) == SQLITE_ROW else { sqlite3_finalize(find); return false }
        let destinationRow = sqlite3_column_int64(find, 0)
        sqlite3_finalize(find)

        var source: OpaquePointer?
        var destination: OpaquePointer?
        defer {
            sqlite3_blob_close(destination)
            sqlite3_blob_close(source)
        }
        guard sqlite3_blob_open(db, "main", "session_cache", "transcript_blob", sourceRow, 0, &source) == SQLITE_OK,
              sqlite3_blob_open(db, "main", "transcript_legacy_blobs", "blob", destinationRow, 1, &destination) == SQLITE_OK
        else { return false }
        return buffer.withUnsafeMutableBytes { raw in
            sqlite3_blob_read(source, raw.baseAddress, Int32(count), Int32(offset)) == SQLITE_OK &&
                sqlite3_blob_write(destination, raw.baseAddress, Int32(count), Int32(offset)) == SQLITE_OK
        }
    }

    /// Publish the copy and drop the inline blob together. Both rows are
    /// matched by length, so a row that changed underneath is not touched.
    private func finishLegacyRelocation(provider: ProviderKind, sessionId: String,
                                        sourceRow: Int64, length: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let db, execute("BEGIN TRANSACTION") else { return false }
        var committed = false
        defer {
            if !committed, sqlite3_get_autocommit(db) == 0 {
                execute("ROLLBACK")
            }
        }

        let transient = sqliteTransient
        let statements: [(String, (OpaquePointer?) -> Void)] = [
            ("""
                UPDATE transcript_legacy_blobs SET complete = 1
                WHERE provider = ? AND session_id = ? AND complete = 0 AND length(blob) = ?
             """, { stmt in
                sqlite3_bind_text(stmt, 1, provider.rawValue, -1, transient)
                sqlite3_bind_text(stmt, 2, sessionId, -1, transient)
                sqlite3_bind_int64(stmt, 3, length)
            }),
            ("""
                UPDATE session_cache SET transcript_blob = NULL
                WHERE rowid = ? AND provider = ? AND session_id = ? AND length(transcript_blob) = ?
             """, { stmt in
                sqlite3_bind_int64(stmt, 1, sourceRow)
                sqlite3_bind_text(stmt, 2, provider.rawValue, -1, transient)
                sqlite3_bind_text(stmt, 3, sessionId, -1, transient)
                sqlite3_bind_int64(stmt, 4, length)
            }),
        ]
        for (sql, bind) in statements {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            bind(stmt)
            let stepped = sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) == 1
            sqlite3_finalize(stmt)
            guard stepped else { return false }
        }
        guard execute("COMMIT") else { return false }
        committed = true
        return true
    }

    /// Reset cache only for sessions that still exist on disk.
    /// Archived sessions (not in liveIds) are preserved.
    func resetLiveSessions(provider: ProviderKind, liveIds: Set<String>) {
        guard !liveIds.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        execute("BEGIN TRANSACTION")
        defer {
            if sqlite3_get_autocommit(db) == 0 {
                execute("ROLLBACK")
            }
        }

        let placeholders = Array(repeating: "?", count: liveIds.count).joined(separator: ",")
        let statements = [
            "DELETE FROM session_cache WHERE provider = ? AND session_id IN (\(placeholders))",
            "DELETE FROM messages WHERE provider = ? AND session_id IN (\(placeholders))"
        ]

        for sql in statements {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, provider.rawValue, -1, sqliteTransient)
            var idx: Int32 = 2
            for id in liveIds {
                sqlite3_bind_text(stmt, idx, id, -1, sqliteTransient)
                idx += 1
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_finalize(stmt)
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

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg {
                print("[DatabaseService] SQL error: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
            return false
        }
        return true
    }

    private func sanitizeFTSQuery(_ raw: String) -> String {
        SearchUtils.ftsQuery(raw)
    }
}

extension DatabaseService {
    /// One session's segmented archive, bound to the session fields the
    /// archive has always carried alongside the transcript.
    struct TranscriptArchive: TranscriptArchiveStore {
        let database: DatabaseService
        let provider: ProviderKind
        let sessionId: String
        let projectPath: String
        let cwd: String?
        let metadata: [String: String]

        func loadArchiveState() -> TranscriptArchiveState? {
            database.transcriptArchiveState(provider: provider, sessionId: sessionId)
        }

        func discardUncommittedSegments(committed: TranscriptArchiveState?) -> Bool {
            database.discardUncommittedTranscriptSegments(provider: provider, sessionId: sessionId, committed: committed)
        }

        func insertSegment(generation: Int64, sourceOffset: Int64, rawLength: Int64, compressed: Data) -> Bool {
            database.insertTranscriptSegment(provider: provider, sessionId: sessionId, generation: generation,
                                             sourceOffset: sourceOffset, rawLength: rawLength, compressed: compressed)
        }

        func commitArchive(_ state: TranscriptArchiveState) -> Bool {
            database.commitTranscriptArchive(provider: provider, sessionId: sessionId, state: state,
                                             projectPath: projectPath, cwd: cwd, metadata: metadata)
        }
    }

    func transcriptArchive(provider: ProviderKind, session: Session) -> TranscriptArchive {
        TranscriptArchive(database: self, provider: provider, sessionId: session.id,
                          projectPath: session.projectPath, cwd: session.cwd, metadata: session.metadata)
    }
}
