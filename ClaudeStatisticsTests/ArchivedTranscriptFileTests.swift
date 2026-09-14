import XCTest

@testable import Claude_Statistics

final class ArchivedTranscriptFileTests: XCTestCase {
    func testTheFileLivesExactlyAsLongAsItsOwner() throws {
        var file = ArchivedTranscriptFile.make(named: "session-id.jsonl") { url in
            FileManager.default.createFile(atPath: url.path, contents: Data("{}\n".utf8))
        }
        let path = try XCTUnwrap(file?.path)
        XCTAssertTrue(path.hasSuffix("/session-id.jsonl"), "keeps the original file name")
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data("{}\n".utf8))
        file = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }

    func testAFailedWriteLeavesNothing() throws {
        var directory: String?
        let file = ArchivedTranscriptFile.make(named: "session-id.jsonl") { url in
            directory = url.deletingLastPathComponent().path
            FileManager.default.createFile(atPath: url.path, contents: Data("partial".utf8))
            return false
        }
        XCTAssertNil(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(directory)))
    }
}
