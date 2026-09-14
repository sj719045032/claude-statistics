import XCTest
import SQLite3
import ClaudeStatisticsKit

@testable import Claude_Statistics

final class DatabaseCheckpointMigrationTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("legacy.db").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func makeLegacyDatabase() throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
            CREATE TABLE session_cache(provider TEXT NOT NULL, session_id TEXT NOT NULL, file_size INTEGER NOT NULL,
                mtime REAL NOT NULL, quick_json TEXT, stats_json TEXT, transcript_blob BLOB,
                project_path TEXT, cwd TEXT, metadata_json TEXT, PRIMARY KEY(provider, session_id));
            CREATE VIRTUAL TABLE messages USING fts5(provider UNINDEXED, session_id UNINDEXED, role UNINDEXED, content, timestamp UNINDEXED);
            INSERT INTO session_cache VALUES('claude','same-id',100,123,'{}','{}',X'010203','project','/work','{"relationship":"preserved"}');
            INSERT INTO session_cache VALUES('codex','same-id',200,456,'{}','{}',X'040506','project','/work','{}');
            INSERT INTO session_cache VALUES('gemini','same-id',300,789,'{}','{}',NULL,'project','/work','{}');
            INSERT INTO messages VALUES('claude','same-id','user','archived searchable text',NULL);
            INSERT INTO messages VALUES('codex','same-id','user','codex searchable text',NULL);
            PRAGMA user_version = 12;
            """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
    }

    func testVersion12MigrationPreservesAllProvidersArchivesAndIndices() throws {
        try makeLegacyDatabase()
        let db = DatabaseService(databasePath: path)
        db.open()
        defer { db.close() }
        XCTAssertEqual(db.loadTranscript(provider: .claude, sessionId: "same-id"), Data([1, 2, 3]))
        XCTAssertEqual(db.loadTranscript(provider: .codex, sessionId: "same-id"), Data([4, 5, 6]))
        XCTAssertEqual(db.loadAllCached(provider: .claude)["same-id"]?.metadata["relationship"], "preserved")
        XCTAssertEqual(db.loadCacheFingerprints(provider: .gemini)["same-id"]?.fileSize, 300)
        XCTAssertEqual(db.search(query: "archived", provider: .claude).count, 1)
        XCTAssertTrue(db.hasCompleteIndex(provider: .claude, sessionId: "same-id"))
        XCTAssertTrue(db.hasCompleteIndex(provider: .codex, sessionId: "same-id"))
        XCTAssertFalse(db.hasCompleteIndex(provider: .gemini, sessionId: "same-id"))
        db.close()
        db.open()
        XCTAssertEqual(db.loadTranscript(provider: .claude, sessionId: "same-id"), Data([1, 2, 3]))
        let checkpoint = SessionParseCheckpoint(parserRevision: "fixture", sources: [:], state: Data())
        XCTAssertTrue(db.saveSessionsStatsAndIndexes(provider: .claude, requests: [
            .init(sessionId: "same-id", fileSize: 100, mtime: Date(), stats: SessionStats(),
                  searchIndexUpdate: .replaceIdentified([.init(id: "message", message: .init(role: "user", content: "new text", timestamp: nil))]),
                  checkpoint: checkpoint)
        ]))
        XCTAssertEqual(db.loadParseCheckpoint(provider: .claude, sessionId: "same-id")?.id, checkpoint.id)
        XCTAssertEqual(db.search(query: "codex", provider: .codex).count, 1)
    }

    func testExplicitResetRecreatesCurrentSchemaIncludingCheckpointColumns() throws {
        let db = DatabaseService(databasePath: path)
        db.open()
        defer { db.close() }
        db.resetDatabase()
        let checkpoint = SessionParseCheckpoint(parserRevision: "fixture", sources: [:], state: Data())
        XCTAssertTrue(db.saveSessionsStatsAndIndexes(provider: .claude, requests: [
            .init(sessionId: "new", fileSize: 100, mtime: Date(), stats: SessionStats(),
                  searchIndexUpdate: .replaceIdentified([]), checkpoint: checkpoint)
        ]))
        db.close()
        db.open()
        XCTAssertEqual(db.loadParseCheckpoint(provider: .claude, sessionId: "new")?.id, checkpoint.id)
        XCTAssertTrue(db.hasCompleteIndex(provider: .claude, sessionId: "new"))
    }
}
