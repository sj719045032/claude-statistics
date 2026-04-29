import Foundation
import Darwin
import SQLite3
import ClaudeStatisticsKit

final class CodexSessionScanner {
    static let shared = CodexSessionScanner()

    static let codexRootPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    static let codexStateDBPath = (codexRootPath as NSString).appendingPathComponent("state_5.sqlite")

    /// Cached SQLite handle to `state_5.sqlite`. Codex writes in WAL mode, so
    /// sqlite WAL appends never bump the main DB file's mtime — keeping a
    /// reader handle open across scans is safe (the read-only lock doesn't
    /// block Codex's PASSIVE checkpoints) and lets us skip the per-scan
    /// `openCodexDB` + `canQueryThreads` schema-prepare cost, which the perf
    /// sample showed dominating after we eliminated the `attributesOfItem`
    /// hot path. Invalidated when the main DB file is replaced (size or
    /// mtime change), e.g. when Codex CLI starts fresh.
    private let dbLock = NSLock()
    private var cachedDB: OpaquePointer?
    private var cachedDBFingerprint: String?

    private init() {}

    deinit {
        if let cachedDB { sqlite3_close(cachedDB) }
    }

    func scanSessions() -> [Session] {
        let dbPath = Self.codexStateDBPath
        guard let db = openOrReuseDB(path: dbPath) else { return [] }

        let sql = """
            SELECT id, rollout_path, title, cwd, created_at, updated_at
            FROM threads
            WHERE archived = 0 AND rollout_path IS NOT NULL
            ORDER BY updated_at DESC
        """

        var stmt: OpaquePointer?
        let prepResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepResult == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            DiagnosticLogger.shared.error("Codex state DB prepare failed (code=\(prepResult)): \(msg)")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var sessions: [Session] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnText(stmt, at: 0),
                  let filePath = columnText(stmt, at: 1),
                  !filePath.isEmpty,
                  let stat = Self.fileStat(at: filePath) else {
                continue
            }

            let title = columnText(stmt, at: 2) ?? ""
            let cwd = columnText(stmt, at: 3) ?? ""
            let createdAt = sqlite3_column_int64(stmt, 4)
            let updatedAt = sqlite3_column_int64(stmt, 5)

            let fileSize = stat.size
            guard fileSize > 0 else { continue }

            let startTime = createdAt > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAt)) : nil
            let fallbackModified = updatedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(updatedAt)) : Date.distantPast
            let lastModified = stat.mtime ?? fallbackModified
            let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectPath = !trimmedCwd.isEmpty ? trimmedCwd : fallbackProjectPath(title: title, filePath: filePath, sessionId: id)

            sessions.append(Session(
                id: id,
                externalID: id,
                provider: "codex",
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

    /// Return a SQLite handle for the Codex DB, reusing the cached one when the
    /// main DB file's size+mtime fingerprint is unchanged. Reopens (closing the
    /// stale handle) when the file has been replaced.
    private func openOrReuseDB(path: String) -> OpaquePointer? {
        guard let stat = Self.fileStat(at: path) else {
            DiagnosticLogger.shared.warning("Codex state DB not found at \(path)")
            return nil
        }
        let fingerprint = "\(stat.size)-\(stat.mtime?.timeIntervalSince1970 ?? 0)"

        dbLock.lock()
        defer { dbLock.unlock() }

        if let existing = cachedDB, cachedDBFingerprint == fingerprint {
            return existing
        }
        if let stale = cachedDB {
            sqlite3_close(stale)
            cachedDB = nil
            cachedDBFingerprint = nil
        }
        guard let fresh = Self.openCodexDB(path: path) else { return nil }
        cachedDB = fresh
        cachedDBFingerprint = fingerprint
        return fresh
    }

    /// One POSIX syscall returning size + mtime. Replaces
    /// `FileManager.attributesOfItem(atPath:)` which on macOS internally walks
    /// extended attributes and `URLResourceValues` — measured at 67% of
    /// `CodexSessionScanner.scanSessions()` CPU per the perf sample. We only
    /// need size + mtime, so a single syscall is ~30× cheaper. Uses `lstat`
    /// (same behaviour as `stat` for non-symlink files) to dodge the Darwin
    /// `stat`-the-struct vs `stat`-the-function name clash.
    fileprivate static func fileStat(at path: String) -> (size: Int64, mtime: Date?)? {
        var st = Darwin.stat()
        guard path.withCString({ lstat($0, &st) }) == 0 else { return nil }
        let size = Int64(st.st_size)
        let secs = TimeInterval(st.st_mtimespec.tv_sec)
        let nsecs = TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return (size, Date(timeIntervalSince1970: secs + nsecs))
    }

    /// Open Codex's state DB read-only, with fallback for WAL mode.
    ///
    /// Codex CLI writes the DB in WAL mode, leaving `-shm` / `-wal` sidecar files.
    /// A plain SQLITE_OPEN_READONLY can fail with SQLITE_CANTOPEN during prepare()
    /// when the reader can't initialise the shared-memory region (e.g. the sidecar
    /// was touched by another process or is in an odd state). Falling back to
    /// `immutable=1` tells SQLite to ignore the WAL/shm files and read straight
    /// from the main DB file — safe since we only read and don't mind slightly
    /// stale data for session listing.
    private static func openCodexDB(path: String) -> OpaquePointer? {
        // Attempt 1: standard read-only (respects WAL)
        var db: OpaquePointer?
        var result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        if result == SQLITE_OK, let db, Self.canQueryThreads(db: db) {
            return db
        }

        let firstErr = db.map { String(cString: sqlite3_errmsg($0)) } ?? "nil handle"
        if let db { sqlite3_close(db) }
        db = nil

        // Attempt 2: URI + immutable=1 (bypass WAL entirely)
        let uri = "file:\(path)?mode=ro&immutable=1"
        result = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        if result == SQLITE_OK, let db, Self.canQueryThreads(db: db) {
            DiagnosticLogger.shared.info("Codex state DB opened via immutable fallback (first attempt: \(firstErr))")
            return db
        }

        let secondErr = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(result)"
        DiagnosticLogger.shared.error("Codex state DB open failed — standard: \(firstErr); immutable: \(secondErr)")
        if let db { sqlite3_close(db) }
        return nil
    }

    /// Verify the DB handle can actually read the threads table — catches the
    /// case where open() succeeds but prepare() later fails with SQLITE_CANTOPEN.
    private static func canQueryThreads(db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT 1 FROM threads LIMIT 1"
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK
    }

    private func fallbackProjectPath(title: String, filePath: String, sessionId: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let parent = (filePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? sessionId : parent
    }

    static func sessionId(forRolloutPath path: String) -> String? {
        guard path.hasSuffix(".jsonl") else { return nil }
        let fileName = (path as NSString).lastPathComponent
        let pattern = #"([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\.jsonl$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: fileName.utf16.count)
        guard let match = regex.firstMatch(in: fileName, options: [], range: range),
              match.numberOfRanges >= 2,
              let idRange = Range(match.range(at: 1), in: fileName) else {
            return nil
        }
        return String(fileName[idRange])
    }
}
