import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// What one forced session rescan costs the host's database, on a clone of the
/// real `data.db`: rewriting every session's metadata and reloading every cache
/// fingerprint. Skipped unless `CLAUDE_STATS_RESCAN_DB` names a clone:
///
///     cp -c ~/Library/.../backups/<backup>.db /tmp/clone.db
///     TEST_RUNNER_CLAUDE_STATS_RESCAN_DB=/tmp/clone.db bash scripts/run-tests.sh
///
/// Never point it at the live database: the measurement writes.
final class ForcedRescanCostRealDataTests: XCTestCase {
    func testForcedRescanDatabaseCost() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_STATS_RESCAN_DB"] else {
            throw XCTSkip("set CLAUDE_STATS_RESCAN_DB to a clone of data.db")
        }
        let database = DatabaseService(databasePath: path)
        database.open()
        defer { database.close() }

        let cached = database.loadAllCached(provider: .codex)
        let sessions = cached.values.map { entry in
            Session(id: entry.sessionId, externalID: entry.sessionId, provider: "codex",
                    projectPath: entry.projectPath ?? "", filePath: "", startTime: nil,
                    lastModified: entry.mtime, fileSize: entry.fileSize, cwd: entry.cwd,
                    metadata: entry.metadata)
        }
        let withMetadata = sessions.filter { !$0.metadata.isEmpty }.count
        XCTAssertGreaterThan(withMetadata, 0)

        let rounds = 5
        var start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<rounds { database.saveSessionMetadata(provider: .codex, sessions: sessions) }
        let metadataMs = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(rounds)

        start = CFAbsoluteTimeGetCurrent()
        var fingerprints = 0
        for _ in 0..<rounds { fingerprints = database.loadCacheFingerprints(provider: .codex).count }
        let fingerprintMs = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(rounds)

        print("[rescan-cost] sessions=\(sessions.count) withMetadata=\(withMetadata) fingerprints=\(fingerprints) " +
              "saveSessionMetadata_ms=\(String(format: "%.2f", metadataMs)) " +
              "loadCacheFingerprints_ms=\(String(format: "%.2f", fingerprintMs))")
    }

    /// Move every pre-v14 archive out of its row on the clone, then time the
    /// same forced-rescan write again. Leaves the clone relocated so the
    /// SQLite CLI can re-measure single-row reads and updates on it.
    func testRelocatingInlineArchivesOnAClone() throws {
        guard let path = ProcessInfo.processInfo.environment["CLAUDE_STATS_RESCAN_DB"],
              ProcessInfo.processInfo.environment["CLAUDE_STATS_RESCAN_RELOCATE"] == "1" else {
            throw XCTSkip("set CLAUDE_STATS_RESCAN_DB and CLAUDE_STATS_RESCAN_RELOCATE=1")
        }
        let database = DatabaseService(databasePath: path)
        database.open()
        defer { database.close() }

        var moved = 0
        var total = 0
        let start = CFAbsoluteTimeGetCurrent()
        for provider in [ProviderKind.claude, .codex, .gemini] {
            let ids = database.sessionsWithInlineLegacyTranscripts(provider: provider)
            total += ids.count
            for id in ids where database.relocateInlineLegacyTranscript(provider: provider, sessionId: id) { moved += 1 }
        }
        let relocateSeconds = CFAbsoluteTimeGetCurrent() - start
        database.checkpoint()

        let cached = database.loadAllCached(provider: .codex)
        let sessions = cached.values.map { entry in
            Session(id: entry.sessionId, externalID: entry.sessionId, provider: "codex",
                    projectPath: entry.projectPath ?? "", filePath: "", startTime: nil,
                    lastModified: entry.mtime, fileSize: entry.fileSize, cwd: entry.cwd,
                    metadata: entry.metadata)
        }
        let rounds = 5
        let metadataStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<rounds { database.saveSessionMetadata(provider: .codex, sessions: sessions) }
        let metadataMs = (CFAbsoluteTimeGetCurrent() - metadataStart) * 1000 / Double(rounds)

        print("[relocation] moved=\(moved)/\(total) seconds=\(String(format: "%.1f", relocateSeconds)) " +
              "after_saveSessionMetadata_ms=\(String(format: "%.2f", metadataMs))")
        XCTAssertEqual(moved, total)
    }
}
