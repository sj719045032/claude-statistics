import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

final class SessionScannerTests: XCTestCase {
    private var sandbox: URL!
    private var standardProjects: URL!
    private var coworkRoot: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionScannerTests-\(UUID().uuidString)", isDirectory: true)
        standardProjects = sandbox.appendingPathComponent("standard-projects", isDirectory: true)
        coworkRoot = sandbox.appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testScansCoworkWhenStandardProjectsDirectoryIsMissing() throws {
        let transcript = try writeCoworkTranscript(
            workspace: "workspace-a",
            session: "session-a",
            local: "local_123",
            project: "-tmp-project",
            filename: "shared-id.jsonl"
        )
        let scanner = makeScanner()

        let sessions = scanner.scanSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].filePath, transcript.path)
        XCTAssertEqual(sessions[0].cwd, "/tmp/project")
        XCTAssertEqual(
            sessions[0].metadata[SessionScanner.coworkOriginMetadataKey],
            SessionScanner.coworkOriginMetadataValue
        )
        XCTAssertFalse(sessions[0].isResumable)
        XCTAssertEqual(TranscriptParser.shared.parseSession(at: transcript.path).totalTokens, 17)
    }

    func testWatchesCoworkParentBeforeSessionsDirectoryExists() {
        let scanner = makeScanner()

        XCTAssertEqual(scanner.coworkWatchDirectory, sandbox.path)
    }

    func testWatchesCoworkRootAfterSessionsDirectoryExists() throws {
        try FileManager.default.createDirectory(at: coworkRoot, withIntermediateDirectories: true)
        let scanner = makeScanner()

        XCTAssertEqual(scanner.coworkWatchDirectory, coworkRoot.path)
    }

    func testCoworkScanOnlyEmitsMainTranscripts() throws {
        let transcript = try writeCoworkTranscript(
            workspace: "workspace-a",
            session: "session-a",
            local: "local_123",
            project: "-tmp-project",
            filename: "main.jsonl"
        )
        let projectDirectory = transcript.deletingLastPathComponent()
        try writeTranscript(
            at: projectDirectory
                .appendingPathComponent("main", isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
                .appendingPathComponent("agent.jsonl")
        )
        try writeTranscript(at: coworkRoot.appendingPathComponent("workspace-a/session-a/audit.jsonl"))
        try writeTranscript(at: coworkRoot.appendingPathComponent("workspace-a/session-a/outputs/result.jsonl"))

        let sessions = makeScanner().scanSessions()

        XCTAssertEqual(sessions.map(\.filePath), [transcript.path])
    }

    func testCoworkSessionIDsAreNamespacedBySandbox() throws {
        try writeCoworkTranscript(
            workspace: "workspace-a",
            session: "session-a",
            local: "local_123",
            project: "-tmp-project",
            filename: "shared-id.jsonl"
        )
        try writeCoworkTranscript(
            workspace: "workspace-b",
            session: "session-b",
            local: "local_456",
            project: "-tmp-project",
            filename: "shared-id.jsonl"
        )

        let sessions = makeScanner().scanSessions()

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.id)).count, 2)
        XCTAssertTrue(sessions.allSatisfy { $0.id.hasPrefix("cowork::") })
    }

    func testChangedCoworkPathResolvesToScannedSessionID() throws {
        let transcript = try writeCoworkTranscript(
            workspace: "workspace-a",
            session: "session-a",
            local: "local_123",
            project: "-tmp-project",
            filename: "session-id.jsonl"
        )
        let scanner = makeScanner()
        let session = try XCTUnwrap(scanner.scanSessions().first)

        XCTAssertTrue(scanner.isCoworkTranscriptPath(transcript.path))
        XCTAssertEqual(scanner.uniqueSessionId(forTranscriptPath: transcript.path), session.id)
    }

    private func makeScanner() -> SessionScanner {
        SessionScanner(
            projectsDirectory: { self.standardProjects.path },
            coworkSessionsDirectory: coworkRoot.path
        )
    }

    @discardableResult
    private func writeCoworkTranscript(
        workspace: String,
        session: String,
        local: String,
        project: String,
        filename: String
    ) throws -> URL {
        let url = coworkRoot
            .appendingPathComponent(workspace, isDirectory: true)
            .appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent(local, isDirectory: true)
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(project, isDirectory: true)
            .appendingPathComponent(filename)
        try writeTranscript(at: url)
        return url
    }

    private func writeTranscript(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = """
        {"type":"assistant","cwd":"/tmp/project","timestamp":"2026-07-16T00:00:00.000Z","message":{"id":"msg_1","model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"text","text":"Cowork fixture payload long enough for the scanner size floor."}]}}
        """
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }
}
