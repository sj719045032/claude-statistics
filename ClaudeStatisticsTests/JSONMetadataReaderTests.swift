import XCTest
import ClaudeStatisticsKit

final class JSONMetadataReaderTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("snapshot.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testMetadataBeforeLargePayloadStopsWithoutReadingMessages() throws {
        let text = "{\"id\":\"session\",\"time\":null,\"messages\":[\"" + String(repeating: "x", count: 1_000_000) + "\"]}"
        try Data(text.utf8).write(to: file)
        let reader = try JSONMetadataReader(path: file.path, chunkSize: 128)
        XCTAssertEqual(try reader.readStringFields(["id", "time"]), ["id": "session"])
        XCTAssertEqual(reader.bytesRead, 128)
    }

    func testNestedAndEscapedPayloadBeforeMetadataAcrossByteBoundaries() throws {
        let payload: [String: Any] = ["messages": [["text": "中文 🌿 \\\" } ]", "nested": [["value": 123], NSNull()]]],
                                      "id": "actual-id", "when": "2026-09-01"]
        try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys).write(to: file)
        for chunk in [1, 7, 128] {
            let reader = try JSONMetadataReader(path: file.path, chunkSize: chunk)
            XCTAssertEqual(try reader.readStringFields(["id", "when"]), ["id": "actual-id", "when": "2026-09-01"])
        }
    }

    func testMissingOptionalFieldsReturnOnlyPresentValues() throws {
        try Data("{\"id\":\"session\",\"number\":123,\"flag\":true}".utf8).write(to: file)
        let reader = try JSONMetadataReader(path: file.path)
        XCTAssertEqual(try reader.readStringFields(["id", "missing", "number"]), ["id": "session"])
    }

    func testPartialMetadataFailsInsteadOfCachingAnEmptyProjection() throws {
        try Data("{\"messages\":[{\"text\":\"unfinished".utf8).write(to: file)
        let reader = try JSONMetadataReader(path: file.path)
        XCTAssertThrowsError(try reader.readStringFields(["id"]))
    }
}
