import XCTest
import SQLite3
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Segmented transcript archive: exact bytes back, only new bytes compressed on
/// append, nothing visible from an interrupted or superseded pass, and pre-v14
/// single-blob archives still readable.
final class TranscriptArchiverTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseService!
    private var source: URL { directory.appendingPathComponent("session.jsonl") }
    private var dbPath: String { directory.appendingPathComponent("archive.db").path }
    private let sessionId = "project::session"
    private let segmentSize = 1_000

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptArchiver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseService(databasePath: dbPath)
        database.open()
        try sql("INSERT INTO session_cache(provider, session_id, file_size, mtime) VALUES('claude', '\(sessionId)', 0, 0)")
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

    private func segmentCount() -> Int { Int(scalar("SELECT COUNT(*) FROM transcript_segments") ?? "") ?? -1 }
    private func generationCount() -> Int {
        Int(scalar("SELECT COUNT(DISTINCT generation) FROM transcript_segments") ?? "") ?? -1
    }
    private func segments(covering bytes: Int) -> Int { (bytes + segmentSize - 1) / segmentSize }

    private func lines(_ count: Int, _ tag: String) -> Data {
        Data((0..<count).map { "{\"n\":\($0),\"text\":\"\(tag) 记录 \($0)\"}\n" }.joined().utf8)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }

    private func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private var session: Session {
        Session(id: sessionId, externalID: "session", provider: "claude", projectPath: "project",
                filePath: source.path, startTime: nil, lastModified: Date(), fileSize: 0)
    }

    private var store: DatabaseService.TranscriptArchive {
        database.transcriptArchive(provider: .claude, session: session)
    }

    @discardableResult
    private func archive() throws -> TranscriptArchiver.Outcome { try archive(store) }

    @discardableResult
    private func archive(_ target: some TranscriptArchiveStore) throws -> TranscriptArchiver.Outcome {
        try TranscriptArchiver.archive(path: source.path, into: target, segmentSize: segmentSize)
    }

    private func archived() -> Data? { database.archivedTranscriptData(provider: .claude, sessionId: sessionId) }

    /// Delegates to the real store, failing on demand to simulate a pass that
    /// dies part-way through.
    private final class FlakyStore: TranscriptArchiveStore {
        let base: DatabaseService.TranscriptArchive
        var insertsBeforeFailure: Int?
        var failCommit = false

        init(_ base: DatabaseService.TranscriptArchive) { self.base = base }

        func loadArchiveState() -> TranscriptArchiveState? { base.loadArchiveState() }
        func discardUncommittedSegments(committed: TranscriptArchiveState?) -> Bool {
            base.discardUncommittedSegments(committed: committed)
        }
        func insertSegment(generation: Int64, sourceOffset: Int64, rawLength: Int64, compressed: Data) -> Bool {
            if let remaining = insertsBeforeFailure {
                guard remaining > 0 else { return false }
                insertsBeforeFailure = remaining - 1
            }
            return base.insertSegment(generation: generation, sourceOffset: sourceOffset,
                                      rawLength: rawLength, compressed: compressed)
        }
        func commitArchive(_ state: TranscriptArchiveState) -> Bool { failCommit ? false : base.commitArchive(state) }
    }

    // MARK: - Round trip and incremental passes

    func testArchiveRoundTripsTheExactBytesInBoundedSegments() throws {
        let data = lines(90, "first")
        try data.write(to: source)

        XCTAssertEqual(try archive(), .rewritten(bytesRead: Int64(data.count)))
        XCTAssertEqual(archived(), data)
        XCTAssertEqual(segmentCount(), segments(covering: data.count))
        XCTAssertLessThanOrEqual(Int(scalar("SELECT MAX(raw_length) FROM transcript_segments") ?? "") ?? .max, segmentSize)
        XCTAssertEqual(database.loadAllCached(provider: .claude)[sessionId]?.hasTranscript, true)
    }

    func testUnchangedSourceIsANoOp() throws {
        try lines(40, "same").write(to: source)
        try archive()
        XCTAssertEqual(try archive(), .unchanged)
    }

    func testAppendCompressesOnlyTheNewBytes() throws {
        let first = lines(60, "first")
        try first.write(to: source)
        try archive()
        let before = segmentCount()

        let addition = lines(5, "added")
        try append(addition)
        XCTAssertEqual(try archive(), .appended(bytesRead: Int64(addition.count)))
        XCTAssertEqual(archived(), first + addition)
        XCTAssertEqual(segmentCount(), before + segments(covering: addition.count))
        XCTAssertEqual(generationCount(), 1, "an append extends the committed generation")
    }

    /// A transcript smaller than one segment is archived as exactly the blob
    /// the pre-v14 archive produced: the formats are the same raw DEFLATE.
    func testASingleSegmentIsByteIdenticalToTheLegacyArchiveBlob() throws {
        let data = lines(10, "small")
        XCTAssertLessThan(data.count, segmentSize)
        try data.write(to: source)
        try archive()
        let legacy = try (data as NSData).compressed(using: .zlib) as Data
        XCTAssertEqual(scalar("SELECT hex(blob) FROM transcript_segments"), hex(legacy))
    }

    // MARK: - Replacement and interruption

    func testReplacedSourceKeepsTheOldArchiveUntilTheNewOneCommits() throws {
        let old = lines(50, "old")
        try old.write(to: source)
        try archive()

        let new = lines(70, "new")
        try new.write(to: source, options: .atomic)   // new inode
        let flaky = FlakyStore(store)
        flaky.failCommit = true
        XCTAssertThrowsError(try archive(flaky))
        XCTAssertEqual(archived(), old, "an uncommitted rewrite must not replace a complete archive")

        XCTAssertEqual(try archive(), .rewritten(bytesRead: Int64(new.count)))
        XCTAssertEqual(archived(), new)
        XCTAssertEqual(generationCount(), 1, "the superseded generation is pruned on commit")
        XCTAssertEqual(segmentCount(), segments(covering: new.count))
    }

    func testTruncateAndRegrowIsRewrittenNotAppended() throws {
        try lines(40, "before").write(to: source)
        try archive()

        let regrown = lines(60, "after")
        let handle = try FileHandle(forWritingTo: source)   // same inode
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: regrown)
        try handle.close()

        XCTAssertEqual(try archive(), .rewritten(bytesRead: Int64(regrown.count)))
        XCTAssertEqual(archived(), regrown)
    }

    func testInterruptedAppendLeavesOnlyTheCommittedPrefixVisible() throws {
        let first = lines(70, "first")
        try first.write(to: source)
        try archive()
        let committedSegments = segmentCount()

        let addition = lines(70, "added")
        try append(addition)
        let flaky = FlakyStore(store)
        flaky.insertsBeforeFailure = 1
        XCTAssertThrowsError(try archive(flaky))
        XCTAssertEqual(archived(), first, "rows past the committed offset are invisible")

        XCTAssertEqual(try archive(), .appended(bytesRead: Int64(addition.count)))
        XCTAssertEqual(archived(), first + addition)
        XCTAssertEqual(segmentCount(), committedSegments + segments(covering: addition.count),
                       "the interrupted pass's orphan row is discarded, not kept")
    }

    func testCancelledPassCommitsNothing() async throws {
        try lines(40, "cancel").write(to: source)
        let path = source.path
        let target = store
        let size = segmentSize
        let outcome = await Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try TranscriptArchiver.archive(path: path, into: target, segmentSize: size)
                return nil
            } catch {
                return error
            }
        }.value
        XCTAssertTrue(outcome is CancellationError)
        XCTAssertNil(archived())
        XCTAssertEqual(segmentCount(), 0)
    }

    func testMissingSessionRowWritesNothing() throws {
        try sql("DELETE FROM session_cache")
        try lines(40, "orphan").write(to: source)
        XCTAssertThrowsError(try archive())
        XCTAssertEqual(segmentCount(), 0)
    }

    // MARK: - Pre-v14 archives

    func testLegacyBlobIsReadableUntilTheFirstSegmentedPassReplacesIt() throws {
        let data = lines(80, "legacy")
        try data.write(to: source)
        let blob = try (data as NSData).compressed(using: .zlib) as Data
        try sql("UPDATE session_cache SET transcript_blob = X'\(hex(blob))'")

        XCTAssertEqual(archived(), data)
        XCTAssertEqual(database.loadAllCached(provider: .claude)[sessionId]?.hasTranscript, true)

        XCTAssertEqual(try archive(), .rewritten(bytesRead: Int64(data.count)))
        XCTAssertEqual(archived(), data)
        XCTAssertEqual(scalar("SELECT transcript_blob IS NULL FROM session_cache"), "1",
                       "the single blob is dropped once segments supersede it")
    }

    func testVersion13DatabaseMigratesAndKeepsItsArchive() throws {
        let legacyPath = directory.appendingPathComponent("v13.db").path
        let data = lines(30, "v13")
        let blob = try (data as NSData).compressed(using: .zlib) as Data
        try sql("""
            CREATE TABLE session_cache(provider TEXT NOT NULL, session_id TEXT NOT NULL, file_size INTEGER NOT NULL,
                mtime REAL NOT NULL, quick_json TEXT, stats_json TEXT, transcript_blob BLOB,
                project_path TEXT, cwd TEXT, metadata_json TEXT, parser_checkpoint BLOB,
                index_complete INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(provider, session_id));
            CREATE TABLE session_index_keys(provider TEXT NOT NULL, session_id TEXT NOT NULL, message_id TEXT NOT NULL,
                fts_rowid INTEGER NOT NULL, PRIMARY KEY(provider, session_id, message_id));
            CREATE VIRTUAL TABLE messages USING fts5(provider UNINDEXED, session_id UNINDEXED, role UNINDEXED, content, timestamp UNINDEXED);
            INSERT INTO session_cache(provider, session_id, file_size, mtime, stats_json, transcript_blob, project_path)
                VALUES('codex', 'kept', 1, 1, '{}', X'\(hex(blob))', 'project');
            PRAGMA user_version = 13;
            """, at: legacyPath)

        let migrated = DatabaseService(databasePath: legacyPath)
        migrated.open()
        defer { migrated.close() }
        XCTAssertEqual(scalar("PRAGMA user_version", at: legacyPath), "15")
        XCTAssertEqual(scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'transcript_segments'", at: legacyPath), "1")
        XCTAssertEqual(migrated.archivedTranscriptData(provider: .codex, sessionId: "kept"), data)
        XCTAssertEqual(migrated.loadAllCached(provider: .codex)["kept"]?.hasTranscript, true)
    }
}
