import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

final class TranscriptFileReaderTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("fixture.jsonl") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func readAll(_ reader: TranscriptFileReader) throws -> [String] {
        var result: [String] = []
        while let record = try reader.readNext() { result.append(String(decoding: record, as: UTF8.self)) }
        return result
    }

    func testChunkBoundariesAndUTF8DoNotChangeRecords() throws {
        let lines = ["第一行", "", String(repeating: "x", count: 100_000), "last"]
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: file)
        for chunkSize in [3, 4096, 65536] {
            let reader = try TranscriptFileReader(path: file.path, chunkSize: chunkSize)
            XCTAssertEqual(try readAll(reader), lines)
            XCTAssertEqual(reader.nextOffset, reader.snapshot.size)
            XCTAssertEqual(reader.bytesRead, reader.snapshot.size)
        }
    }

    func testPartialTailIsRetriedFromLastCompleteRecord() throws {
        try Data("first\npar".utf8).write(to: file)
        let reader = try TranscriptFileReader(path: file.path, chunkSize: 2)
        XCTAssertEqual(try readAll(reader), ["first"])
        XCTAssertEqual(reader.nextOffset, 6)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tial\n".utf8))
        try handle.close()
        let next = try TranscriptFileReader(path: file.path, fromOffset: reader.nextOffset)
        XCTAssertEqual(try readAll(next), ["partial"])
    }

    /// `FileHandle.read` returns autoreleased data. Reading a whole file
    /// without draining it per chunk keeps every chunk alive until the parse
    /// returns, so a "chunked" read costs the whole file — an 869 MB real
    /// Codex rollout measured 944 MB of peak footprint before this was fixed.
    func testReadingAWholeFileDoesNotRetainItsChunks() throws {
        let record = Data((String(repeating: "y", count: 4_000) + "\n").utf8)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        for _ in 0..<20_000 { try handle.write(contentsOf: record) }   // ~80 MB
        try handle.close()

        var records = 0
        var live = 0
        var readBytes: Int64 = 0
        // The pool bounds XCTest's own autoreleased objects, not the reader's:
        // a reader that retains its chunks still shows them as live inside it.
        try autoreleasepool {
            let before = AllocationProbe.liveBytes()
            let reader = try TranscriptFileReader(path: file.path)
            while let next = try reader.readNext() {
                records += 1
                XCTAssertEqual(next.count, 4_000)
            }
            live = AllocationProbe.liveBytes() - before
            readBytes = reader.bytesRead
        }

        XCTAssertEqual(records, 20_000)
        XCTAssertEqual(readBytes, 80_020_000)
        XCTAssertLessThan(live, 16 * 1024 * 1024,
                          "reading 80 MB in chunks must not retain the file (\(live) bytes live)")
    }

    func testOneGigabyteHistoryAppendReadsOnlyNewBytes() throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        let historySize: UInt64 = 1024 * 1024 * 1024
        try handle.truncate(atOffset: historySize) // Sparse fixture, no 1 GB allocation/write.
        try handle.seek(toOffset: historySize)
        let addition = Data("{\"message\":\"new\"}\n".utf8)
        try handle.write(contentsOf: addition)
        try handle.close()
        let reader = try TranscriptFileReader(path: file.path, fromOffset: Int64(historySize))
        XCTAssertEqual(try readAll(reader), ["{\"message\":\"new\"}"])
        XCTAssertEqual(reader.bytesRead, Int64(addition.count))
    }

    func testSnapshotDoesNotConsumeBytesAppendedAfterOpening() throws {
        try Data("first\n".utf8).write(to: file)
        let reader = try TranscriptFileReader(path: file.path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()
        XCTAssertEqual(try readAll(reader), ["first"])
        XCTAssertEqual(reader.nextOffset, 6)
    }

    func testFullSnapshotCanReadUnterminatedFinalLine() throws {
        try Data("first\nlast".utf8).write(to: file)
        let reader = try TranscriptFileReader(path: file.path, includeFinalLine: true)
        XCTAssertEqual(try readAll(reader), ["first", "last"])
        XCTAssertEqual(reader.nextOffset, 10)
    }

    func testReplacementIsDetectedEvenWhenSizeIsUnchanged() throws {
        try Data("first\n".utf8).write(to: file)
        let reader = try TranscriptFileReader(path: file.path)
        try Data("other\n".utf8).write(to: file, options: .atomic)
        let replacement = try TranscriptFileSnapshot.read(at: file.path)
        XCTAssertEqual(reader.snapshot.size, replacement.size)
        XCTAssertFalse(reader.snapshot.hasSameIdentity(as: replacement))
        XCTAssertThrowsError(try reader.validateSnapshot())
    }

    func testMutationAfterReadPreventsSuccessfulSnapshotValidation() throws {
        try Data("first\n".utf8).write(to: file)
        let reader = try TranscriptFileReader(path: file.path)
        XCTAssertEqual(try readAll(reader), ["first"])
        try reader.validateSnapshot()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()
        XCTAssertThrowsError(try reader.validateSnapshot())
    }

    func testCheckpointCompletesItsSnapshotWhileWriterKeepsAppending() throws {
        try Data("{\"id\":1}\n{\"id\":2}\n".utf8).write(to: file)
        let reader = try CheckpointedJSONLReader(path: file.path, checkpoint: nil)
        XCTAssertEqual(try reader.readNext()?.value["id"] as? Int, 1)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":3}\n".utf8))
        XCTAssertEqual(try reader.readNext()?.value["id"] as? Int, 2)
        XCTAssertNil(try reader.readNext())
        let checkpoint = try reader.finish()
        XCTAssertEqual(checkpoint.offset, reader.snapshot.size)
        XCTAssertLessThan(checkpoint.offset, try TranscriptFileSnapshot.read(at: file.path).size)
        let next = try CheckpointedJSONLReader(path: file.path, checkpoint: checkpoint)
        XCTAssertTrue(next.isIncremental)
        try handle.write(contentsOf: Data("{\"id\":4}\n".utf8))
        try handle.close()
        XCTAssertEqual(try next.readNext()?.value["id"] as? Int, 3)
        XCTAssertNil(try next.readNext())
        let third = try CheckpointedJSONLReader(path: file.path, checkpoint: next.finish())
        XCTAssertEqual(try third.readNext()?.value["id"] as? Int, 4)
        XCTAssertNil(try third.readNext())
        _ = try third.finish()
    }

    func testAppendValidationRejectsBoundaryRewriteAndReplacement() throws {
        for replaceAtomically in [false, true] {
            try Data("{\"id\":1}\n".utf8).write(to: file)
            let reader = try CheckpointedJSONLReader(path: file.path, checkpoint: nil)
            _ = try reader.readNext()
            let changed = Data("{\"id\":9}\n{\"id\":2}\n".utf8)
            try changed.write(to: file, options: replaceAtomically ? .atomic : [])
            XCTAssertThrowsError(try reader.finish())
        }
    }

    func testContinuitySamplesStayBoundedAcrossLargeHistory() throws {
        let history = Data(repeating: 0x61, count: 100_000)
        try history.write(to: file)
        let before = try TranscriptFileContinuity.read(at: file.path, upTo: Int64(history.count))
        XCTAssertEqual(TranscriptFileContinuity.sampledBytes(upTo: Int64(history.count)), 2048)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("appended".utf8))
        XCTAssertEqual(try TranscriptFileContinuity.read(at: file.path, upTo: Int64(history.count)), before)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("changed".utf8))
        try handle.close()
        XCTAssertNotEqual(try TranscriptFileContinuity.read(at: file.path, upTo: Int64(history.count)), before)
    }

    func testTruncationDuringReadIsNotTreatedAsSuccessfulEOF() throws {
        try Data("first\nsecond\n".utf8).write(to: file)
        let reader = try TranscriptFileReader(path: file.path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.close()
        XCTAssertThrowsError(try reader.readNext())
    }

    func testStreamingAndDataSearchIndexProjectionsAgree() throws {
        let content = """
        {"type":"user","message":{"content":"Find this exact message"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"A searchable reply"}]}}
        """
        let data = Data(content.utf8)
        try data.write(to: file)
        let streaming = TranscriptParser.shared.parseSearchIndexMessages(at: file.path)
        let loaded = TranscriptParser.shared.parseSearchIndexMessages(fromData: data)
        XCTAssertFalse(streaming.isEmpty)
        XCTAssertEqual(streaming.map(\.content), loaded.map(\.content))
        XCTAssertEqual(streaming.map(\.role), loaded.map(\.role))
    }

    func testUnchangedFileAtCheckpointPerformsNoReads() throws {
        try Data("record\n".utf8).write(to: file)
        let state = try TranscriptFileSnapshot.read(at: file.path)
        let reader = try TranscriptFileReader(path: file.path, fromOffset: state.size)
        XCTAssertNil(try reader.readNext())
        XCTAssertEqual(reader.bytesRead, 0)
        XCTAssertEqual(reader.nextOffset, state.size)
    }

    func testSubsecondSameSizeRewriteChangesFingerprint() throws {
        try Data("record\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
        let before = try TranscriptFileSnapshot.read(at: file.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100.1)], ofItemAtPath: file.path)
        let after = try TranscriptFileSnapshot.read(at: file.path)
        XCTAssertTrue(before.hasSameIdentity(as: after))
        XCTAssertEqual(before.size, after.size)
        XCTAssertNotEqual(before, after)
    }

    func testIndexReadFailureRejectsPartialProjection() {
        enum Failure: Error { case interrupted }
        var calls = 0
        XCTAssertThrowsError(try TranscriptParser.shared.parseSearchIndexMessages(nextLine: {
            calls += 1
            if calls == 1 {
                return Data("{\"type\":\"user\",\"message\":{\"content\":\"original searchable text\"}}".utf8)
            }
            throw Failure.interrupted
        }))
    }
}
