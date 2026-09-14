import XCTest
import SQLite3
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Pre-v14 archives are moved out of `session_cache` rows so reading or
/// updating the columns stored after them stops walking the blob. The move
/// must keep the exact bytes, never expose a half-written copy, and yield to a
/// segmented archive that supersedes it.
final class LegacyTranscriptRelocationTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseService!
    private var dbPath: String { directory.appendingPathComponent("relocate.db").path }
    private let sessionId = "project::session"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyRelocation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseService(databasePath: dbPath)
        database.open()
    }

    override func tearDownWithError() throws {
        database.close()
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func sql(_ statement: String, at path: String? = nil) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path ?? dbPath, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: String(cString: sqlite3_errmsg(handle)), code: 1)
        }
    }

    private func scalar(_ query: String, at path: String? = nil) -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open(path ?? dbPath, &handle) == SQLITE_OK else { return nil }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: text)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }

    private func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// A session row holding its archive inline, the way pre-v14 builds wrote it.
    private func seedInlineArchive(_ blob: Data, id: String? = nil) throws {
        try sql("""
            INSERT INTO session_cache(provider, session_id, file_size, mtime, stats_json, transcript_blob, metadata_json)
            VALUES('claude', '\(id ?? sessionId)', 1, 1, '{}', X'\(hex(blob))', '{"k":"v"}')
            """)
    }

    private var inlineIsGone: Bool {
        scalar("SELECT transcript_blob IS NULL FROM session_cache WHERE session_id = '\(sessionId)'") == "1"
    }

    // MARK: - Relocation

    func testRelocationMovesTheExactBytesOutOfTheRow() throws {
        let blob = randomBytes(10_003)
        try seedInlineArchive(blob)
        XCTAssertEqual(database.sessionsWithInlineLegacyTranscripts(provider: .claude), [sessionId])

        // A chunk size that does not divide the blob exercises every boundary.
        XCTAssertTrue(database.relocateInlineLegacyTranscript(provider: .claude, sessionId: sessionId, chunkBytes: 7))

        XCTAssertTrue(inlineIsGone)
        XCTAssertEqual(database.loadTranscript(provider: .claude, sessionId: sessionId), blob)
        XCTAssertEqual(database.loadAllCached(provider: .claude)[sessionId]?.hasTranscript, true)
        XCTAssertEqual(database.loadAllCached(provider: .claude)[sessionId]?.metadata["k"], "v",
                       "columns after the old blob survive the move")
        XCTAssertTrue(database.sessionsWithInlineLegacyTranscripts(provider: .claude).isEmpty)
    }

    func testARelocatedArchiveStillDecodes() throws {
        let transcript = Data((0..<200).map { "{\"n\":\($0),\"t\":\"记录 \($0)\"}\n" }.joined().utf8)
        try seedInlineArchive(try (transcript as NSData).compressed(using: .zlib) as Data)
        XCTAssertTrue(database.relocateInlineLegacyTranscript(provider: .claude, sessionId: sessionId))
        XCTAssertEqual(database.archivedTranscriptData(provider: .claude, sessionId: sessionId), transcript)
    }

    func testAnIncompleteCopyIsNeverReadAndIsDiscarded() throws {
        let blob = randomBytes(512)
        try seedInlineArchive(blob)
        try sql("INSERT INTO transcript_legacy_blobs VALUES('claude', '\(sessionId)', 0, X'DEADBEEF')")

        XCTAssertEqual(database.loadTranscript(provider: .claude, sessionId: sessionId), blob,
                       "a half-written copy must not shadow the inline archive")
        XCTAssertTrue(database.discardIncompleteLegacyRelocations(provider: .claude))
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM transcript_legacy_blobs"), "0")
    }

    func testCancelledRelocationPublishesNothing() async throws {
        let blob = randomBytes(64_000)
        try seedInlineArchive(blob)
        let database = self.database!
        let id = sessionId
        let relocated = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return database.relocateInlineLegacyTranscript(provider: .claude, sessionId: id, chunkBytes: 1_000)
        }.value
        XCTAssertFalse(relocated)
        XCTAssertFalse(inlineIsGone)
        XCTAssertEqual(database.loadTranscript(provider: .claude, sessionId: sessionId), blob)
    }

    func testNothingToRelocateLeavesNoCopy() throws {
        try sql("INSERT INTO session_cache(provider, session_id, file_size, mtime) VALUES('claude', '\(sessionId)', 1, 1)")
        XCTAssertFalse(database.relocateInlineLegacyTranscript(provider: .claude, sessionId: sessionId))
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM transcript_legacy_blobs"), "0")
    }

    func testASegmentedArchiveSupersedesARelocatedBlob() throws {
        try seedInlineArchive(randomBytes(300))
        XCTAssertTrue(database.relocateInlineLegacyTranscript(provider: .claude, sessionId: sessionId))

        let source = directory.appendingPathComponent("session.jsonl")
        let data = Data((0..<50).map { "{\"n\":\($0)}\n" }.joined().utf8)
        try data.write(to: source)
        let session = Session(id: sessionId, externalID: "session", provider: "claude", projectPath: "project",
                              filePath: source.path, startTime: nil, lastModified: Date(), fileSize: 0)
        _ = try TranscriptArchiver.archive(path: source.path,
                                           into: database.transcriptArchive(provider: .claude, session: session))

        XCTAssertEqual(scalar("SELECT COUNT(*) FROM transcript_legacy_blobs"), "0")
        XCTAssertEqual(database.archivedTranscriptData(provider: .claude, sessionId: sessionId), data)
    }

    func testVersion14DatabaseMigratesTo15WithItsInlineArchive() throws {
        let legacyPath = directory.appendingPathComponent("v14.db").path
        let blob = randomBytes(256)
        try sql("""
            CREATE TABLE session_cache(provider TEXT NOT NULL, session_id TEXT NOT NULL, file_size INTEGER NOT NULL,
                mtime REAL NOT NULL, quick_json TEXT, stats_json TEXT, transcript_blob BLOB,
                project_path TEXT, cwd TEXT, metadata_json TEXT, parser_checkpoint BLOB,
                index_complete INTEGER NOT NULL DEFAULT 0, archive_state BLOB, PRIMARY KEY(provider, session_id));
            CREATE TABLE session_index_keys(provider TEXT NOT NULL, session_id TEXT NOT NULL, message_id TEXT NOT NULL,
                fts_rowid INTEGER NOT NULL, PRIMARY KEY(provider, session_id, message_id));
            CREATE TABLE transcript_segments(provider TEXT NOT NULL, session_id TEXT NOT NULL, generation INTEGER NOT NULL,
                source_offset INTEGER NOT NULL, raw_length INTEGER NOT NULL, blob BLOB NOT NULL,
                PRIMARY KEY(provider, session_id, generation, source_offset));
            CREATE VIRTUAL TABLE messages USING fts5(provider UNINDEXED, session_id UNINDEXED, role UNINDEXED, content, timestamp UNINDEXED);
            INSERT INTO session_cache(provider, session_id, file_size, mtime, stats_json, transcript_blob)
                VALUES('gemini', 'kept', 1, 1, '{}', X'\(hex(blob))');
            PRAGMA user_version = 14;
            """, at: legacyPath)

        let migrated = DatabaseService(databasePath: legacyPath)
        migrated.open()
        defer { migrated.close() }
        XCTAssertEqual(scalar("PRAGMA user_version", at: legacyPath), "15")
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'transcript_legacy_blobs'", at: legacyPath), "1")
        XCTAssertEqual(migrated.loadTranscript(provider: .gemini, sessionId: "kept"), blob,
                       "migration adds the table; it does not move data")
        XCTAssertTrue(migrated.relocateInlineLegacyTranscript(provider: .gemini, sessionId: "kept"))
        XCTAssertEqual(migrated.loadTranscript(provider: .gemini, sessionId: "kept"), blob)
    }

    /// A pre-v14 archive is inflated into the file a chunk at a time — here in
    /// 1 KiB reads, far smaller than the compressed blob — inline or relocated.
    func testALegacyArchiveStreamsToAFileInSmallChunks() throws {
        let transcript = Data((0..<5_000).map { "{\"n\":\($0),\"t\":\"记录 \($0) \(UUID().uuidString)\"}\n" }.joined().utf8)
        let compressed = try (transcript as NSData).compressed(using: .zlib) as Data
        XCTAssertGreaterThan(compressed.count, 8 * 1024)
        try seedInlineArchive(compressed)
        XCTAssertEqual(database.archivedTranscriptData(provider: .claude, sessionId: sessionId, chunkBytes: 1024), transcript)
        XCTAssertTrue(database.relocateInlineLegacyTranscript(provider: .claude, sessionId: sessionId))
        XCTAssertEqual(database.archivedTranscriptData(provider: .claude, sessionId: sessionId, chunkBytes: 1024), transcript)
    }

    func testATruncatedLegacyArchiveLeavesNoFile() throws {
        let transcript = Data((0..<2_000).map { "{\"n\":\($0),\"id\":\"\(UUID().uuidString)\"}\n" }.joined().utf8)
        let compressed = try (transcript as NSData).compressed(using: .zlib) as Data
        try seedInlineArchive(compressed.prefix(compressed.count / 2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("truncated-\(UUID().uuidString).jsonl")
        XCTAssertFalse(database.writeArchivedTranscript(provider: .claude, sessionId: sessionId, to: url, chunkBytes: 256))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

