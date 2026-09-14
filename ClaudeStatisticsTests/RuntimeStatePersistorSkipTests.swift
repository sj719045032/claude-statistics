import Foundation
import XCTest

@testable import Claude_Statistics

/// `ActiveSessionsTracker.refresh()` persists on every tick, including the
/// 15 s timer. An unchanged state must not be rewritten to disk each time.
@MainActor
final class RuntimeStatePersistorSkipTests: XCTestCase {
    private var tempDir: URL!
    private var fileURL: URL { tempDir.appendingPathComponent("runtime.json") }

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RuntimeStatePersistorSkip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func session(_ id: String, activity: String) throws -> RuntimeSession {
        let json: [String: Any] = [
            "provider": ProviderKind.claude.rawValue, "sessionId": id,
            "lastActivityAt": Date(timeIntervalSinceReferenceDate: 1_000).timeIntervalSinceReferenceDate,
            "status": "idle", "backgroundShellCount": 0, "activeSubagentCount": 0,
            "activeTools": [String: Any](), "currentActivity": activity,
        ]
        return try JSONDecoder().decode(RuntimeSession.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// Past the 0.4 s write debounce.
    private func settle() async throws { try await Task.sleep(nanoseconds: 700_000_000) }

    private func inode() throws -> UInt64 {
        // The writer replaces the file atomically, so a rewrite gets a new inode.
        (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.systemFileNumber] as? UInt64) ?? 0
    }

    func testAnUnchangedStateIsNotRewritten() async throws {
        let persistor = RuntimeStatePersistor(fileURL: fileURL)
        let state = ["claude:a": try session("a", activity: "reading")]
        persistor.scheduleWrite(state)
        try await settle()
        let first = try inode()

        persistor.scheduleWrite(state)
        try await settle()
        XCTAssertEqual(try inode(), first, "an identical state must not be written again")

        persistor.scheduleWrite(["claude:a": try session("a", activity: "editing")])
        try await settle()
        XCTAssertNotEqual(try inode(), first, "a changed state is written")
    }
}
