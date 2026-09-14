import XCTest
import ClaudeStatisticsKit
import SQLite3

@testable import Claude_Statistics

final class SessionIndexUpdateTests: XCTestCase {
    private var database: DatabaseService!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseService(databasePath: directory.appendingPathComponent("test.db").path)
        database.open()
    }

    override func tearDownWithError() throws {
        database.close()
        database = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func request(_ update: DatabaseService.SearchIndexUpdate, size: Int64 = 100,
                         stats: SessionStats = SessionStats()) -> DatabaseService.SaveSessionStatsRequest {
        .init(sessionId: "session", fileSize: size, mtime: Date(timeIntervalSince1970: 100),
              stats: stats, searchIndexUpdate: update)
    }

    func testStatisticsOnlyUpdatePreservesSearchRecords() {
        let messages = [SearchIndexMessage(role: "user", content: "searchable original message", timestamp: nil)]
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.replace(messages))]))
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.preserve, size: 200)]))
        XCTAssertEqual(database.search(query: "original", provider: .claude).count, 1)
        XCTAssertEqual(database.loadCacheFingerprints(provider: .claude)["session"]?.fileSize, 200)
    }

    func testExplicitEmptyReplacementClearsSearchRecords() {
        let messages = [SearchIndexMessage(role: "user", content: "searchable original message", timestamp: nil)]
        database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.replace(messages))])
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.replace([]))]))
        XCTAssertTrue(database.search(query: "original", provider: .claude).isEmpty)
    }

    func testFailedBatchRollsBackFingerprintAndIndexTogether() {
        let messages = [SearchIndexMessage(role: "user", content: "original message", timestamp: nil)]
        database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.replace(messages))])
        var invalid = SessionStats()
        invalid.startTime = Date(timeIntervalSince1970: .infinity)
        let batch = [request(.replace([]), size: 200), request(.preserve, size: 300, stats: invalid)]
        XCTAssertFalse(database.saveSessionsStatsAndIndexes(provider: .claude, requests: batch))
        XCTAssertEqual(database.search(query: "original", provider: .claude).count, 1)
        XCTAssertEqual(database.loadCacheFingerprints(provider: .claude)["session"]?.fileSize, 100)
    }

    func testProviderIndicesRemainIsolated() {
        let messages = [SearchIndexMessage(role: "user", content: "original message", timestamp: nil)]
        for provider in [ProviderKind.claude, .codex, .gemini] {
            database.saveSessionsStatsAndIndexes(provider: provider, requests: [request(.replace(messages))])
        }
        database.saveSessionsStatsAndIndexes(provider: .codex, requests: [request(.replace([]))])
        XCTAssertEqual(database.search(query: "original", provider: .claude).count, 1)
        XCTAssertTrue(database.search(query: "original", provider: .codex).isEmpty)
        XCTAssertEqual(database.search(query: "original", provider: .gemini).count, 1)
    }

    private func identified(_ id: String, _ text: String) -> IdentifiedSearchIndexMessage {
        .init(id: id, message: .init(role: "assistant", content: text, timestamp: nil))
    }

    private func checkpoint(_ state: String) -> SessionParseCheckpoint {
        .init(parserRevision: "fixture-v1", sources: [:], state: Data(state.utf8))
    }

    private func checkpointRequest(_ checkpoint: SessionParseCheckpoint, expected: DatabaseService.CheckpointExpectation = .any,
                                   index: SessionSearchIndexUpdate = .update(upserting: [], removing: []),
                                   size: Int64 = 100) -> DatabaseService.SaveSessionStatsRequest {
        .init(sessionId: "session", fileSize: size, mtime: Date(timeIntervalSince1970: 100), stats: SessionStats(),
              searchIndexUpdate: index, checkpoint: checkpoint, expectedCheckpoint: expected)
    }

    func testIncrementalIndexReplacesOnlyChangedIDs() {
        database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.replaceIdentified([
            identified("a", "original answer"), identified("b", "untouched answer")
        ]))])
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.update(
            upserting: [identified("a", "updated answer")], removing: []
        ))]))
        XCTAssertTrue(database.search(query: "original", provider: .claude).isEmpty)
        XCTAssertEqual(database.search(query: "updated", provider: .claude).count, 1)
        XCTAssertEqual(database.search(query: "untouched", provider: .claude).count, 1)
    }

    func testReplayedAndDuplicateIDsAreIdempotent() throws {
        let update = request(.update(upserting: [identified("a", "partial answer"), identified("a", "final answer")], removing: []))
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [update]))
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [update]))
        XCTAssertTrue(database.search(query: "partial", provider: .claude).isEmpty)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appendingPathComponent("test.db").path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "SELECT count(*) FROM messages", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testExplicitRemovalCanLeaveACompleteEmptyIndex() {
        database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.replaceIdentified([identified("a", "original answer")]))])
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.update(upserting: [], removing: ["a"]))]))
        XCTAssertTrue(database.search(query: "original", provider: .claude).isEmpty)
        XCTAssertTrue(database.sessionsWithCompleteIndex(provider: .claude).contains("session"))
    }

    func testCheckpointSurvivesDatabaseReopen() {
        let saved = checkpoint("state and cursor")
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [checkpointRequest(saved)]))
        database.close()
        database.open()
        let restored = database.loadParseCheckpoint(provider: .claude, sessionId: "session")
        XCTAssertEqual(restored?.id, saved.id)
        XCTAssertEqual(restored?.state, saved.state)
        XCTAssertEqual(restored?.parserRevision, "fixture-v1")
    }

    func testStaleCheckpointCannotOverwriteNewerCommit() {
        let first = checkpoint("first")
        let second = checkpoint("second")
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [checkpointRequest(first, expected: .matches(nil))]))
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [checkpointRequest(second, expected: .matches(first.id), size: 200)]))
        XCTAssertFalse(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [checkpointRequest(checkpoint("stale"), expected: .matches(first.id), size: 300)]))
        XCTAssertEqual(database.loadParseCheckpoint(provider: .claude, sessionId: "session")?.id, second.id)
        XCTAssertEqual(database.loadCacheFingerprints(provider: .claude)["session"]?.fileSize, 200)
    }

    func testRollbackPreservesCheckpointAndIndexTogether() {
        let first = checkpoint("first")
        database.saveSessionsStatsAndIndexes(provider: .claude, requests: [checkpointRequest(first, index: .replaceIdentified([identified("a", "original answer")]))])
        var invalid = SessionStats()
        invalid.startTime = Date(timeIntervalSince1970: .infinity)
        let requests = [checkpointRequest(checkpoint("second"), index: .update(upserting: [identified("a", "updated answer")], removing: [])),
                        request(.preserve, stats: invalid)]
        XCTAssertFalse(database.saveSessionsStatsAndIndexes(provider: .claude, requests: requests))
        XCTAssertEqual(database.loadParseCheckpoint(provider: .claude, sessionId: "session")?.id, first.id)
        XCTAssertEqual(database.search(query: "original", provider: .claude).count, 1)
        XCTAssertTrue(database.search(query: "updated", provider: .claude).isEmpty)
    }

    func testPreservedIndexBecomesStaleWhenFileChanges() {
        database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.replace([]))])
        XCTAssertTrue(database.sessionsWithCompleteIndex(provider: .claude).contains("session"))
        database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.preserve, size: 200)])
        XCTAssertFalse(database.sessionsWithCompleteIndex(provider: .claude).contains("session"))
    }

    func testLegacyFullParseInvalidatesCheckpointAndStableKeys() {
        database.saveSessionsStatsAndIndexes(provider: .claude, requests: [checkpointRequest(checkpoint("first"), index: .replaceIdentified([identified("a", "original answer")]))])
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.replace([]))]))
        XCTAssertNil(database.loadParseCheckpoint(provider: .claude, sessionId: "session"))
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request(.update(upserting: [identified("a", "fresh answer")], removing: []))]))
        XCTAssertEqual(database.search(query: "fresh", provider: .claude).count, 1)
    }
}
