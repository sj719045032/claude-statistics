import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Every real Claude transcript on this machine must parse and commit through
/// the path the store uses, without asking for a retry. A refused commit is
/// silent in the app: the session keeps its stale statistics and retries on
/// every refresh. Transcripts are only read; the database is a temp file.
/// Skipped unless `TEST_RUNNER_CLAUDE_STATS_REAL_DATA=1`.
final class ClaudeCommitRealDataTests: XCTestCase {
    func testEveryRealTranscriptCommitsWithoutRetry() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDE_STATS_REAL_DATA"] == "1" else {
            throw XCTSkip("set CLAUDE_STATS_REAL_DATA=1")
        }
        // Session transcripts only, as the scanner sees them: `<projects>/<project>/<id>.jsonl`.
        // Deeper JSONL files are subagent transcripts or other tools' logs.
        let projects = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects"))
            .standardizedFileURL.path
        let roots = RealClaudeTranscripts.largest(.max).filter {
            $0.url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == projects
        }
        try XCTSkipIf(roots.isEmpty, "no local Claude transcripts")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CommitRealData-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = DatabaseService(databasePath: directory.appendingPathComponent("commit.db").path)
        database.open()
        defer { database.close() }

        var retried: [String] = []
        for root in roots {
            let path = root.url.path
            guard let snapshot = try? TranscriptFileSnapshot.read(at: path) else { continue }
            let externalID = root.url.deletingPathExtension().lastPathComponent
            let project = root.url.deletingLastPathComponent().lastPathComponent
            let session = Session(id: "\(project)::\(externalID)", externalID: externalID, provider: "claude",
                                  projectPath: project, filePath: path,
                                  startTime: nil, lastModified: snapshot.modifiedAt, fileSize: snapshot.size)
            let outcome = await SessionParseValidator.parseAndCommit(
                provider: ClaudeProvider.shared, session: session, quick: SessionQuickStats(),
                cached: nil, database: database
            )
            if outcome.shouldRetry { retried.append(session.id) }
        }
        print("[commit-real-data] transcripts=\(roots.count) retried=\(retried.count)")
        XCTAssertEqual(retried, [], "sessions whose commit was refused")
    }
}
