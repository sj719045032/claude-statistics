import XCTest
import Combine
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Exercises the public plugin capability through the actual host validator,
/// database transaction, and store. The fixture format is intentionally tiny;
/// provider-format equivalence is tested separately by each real adapter.
@MainActor
final class CheckpointedSessionPipelineTests: XCTestCase {
    private final class FixtureProvider: SessionProvider, CheckpointedSessionDataProvider, @unchecked Sendable {
        struct State: Codable { var tokens = 0; var messages = 0 }
        let providerId = "claude"
        let displayName = "Checkpoint fixture"
        let capabilities = ProviderCapabilities.claude
        let configDirectory: String
        let checkpointParserRevision = "fixture-1"
        let usageSource: (any ProviderUsageSource)? = nil
        let path: String

        init(path: String) { self.path = path; configDirectory = (path as NSString).deletingLastPathComponent }
        func scanSessions() -> [Session] {
            guard let snapshot = try? TranscriptFileSnapshot.read(at: path) else { return [] }
            return [Session(id: "fixture", externalID: "fixture", provider: providerId, projectPath: configDirectory,
                            filePath: path, startTime: nil, lastModified: snapshot.modifiedAt, fileSize: snapshot.size)]
        }
        func resolvedProjectPath(for session: Session) -> String { configDirectory }
        func makeWatcher(onChange: @escaping (Set<String>) -> Void) -> (any SessionWatcher)? { nil }
        func parseQuickStats(at path: String) -> SessionQuickStats { XCTFail("Checkpoint path must not invoke legacy quick parse"); return SessionQuickStats() }
        func parseSession(at path: String) -> SessionStats { XCTFail("Checkpoint path must not invoke legacy full parse"); return SessionStats() }
        func parseMessages(at path: String) -> [TranscriptDisplayMessage] { [] }
        func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] { XCTFail("Checkpoint path must produce its own index"); return [] }
        func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] { [] }
        func openNewSession(_ session: Session) {}
        func resumeSession(_ session: Session) {}
        func openNewSession(inDirectory path: String) {}
        func resumeCommand(for session: Session) -> String { "" }

        func parseSessionUpdate(at path: String, checkpoint: SessionParseCheckpoint?) throws -> CheckpointedSessionUpdate? {
            let current = try TranscriptFileSnapshot.read(at: path)
            let prior = checkpoint?.sources[path]
            if prior?.snapshot == current { return nil }
            let appending = prior.map { $0.snapshot.hasSameIdentity(as: current) && current.size > $0.snapshot.size } ?? false
            var state = appending ? try JSONDecoder().decode(State.self, from: checkpoint!.state) : State()
            let reader = try TranscriptFileReader(path: path, fromOffset: appending ? prior!.offset : 0)
            var messages: [IdentifiedSearchIndexMessage] = []
            while true {
                let offset = reader.nextOffset
                guard let data = try reader.readNext() else { break }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tokens = json["tokens"] as? Int, let text = json["text"] as? String else { continue }
                state.tokens += tokens
                state.messages += 1
                messages.append(.init(id: String(offset), message: .init(role: "user", content: text, timestamp: nil)))
            }
            var stats = SessionStats()
            stats.model = "fixture"
            stats.startTime = Date(timeIntervalSince1970: 100)
            stats.endTime = stats.startTime
            stats.userMessageCount = state.messages
            stats.fiveMinSlices[stats.startTime!] = DaySlice(totalInputTokens: state.tokens, messageCount: state.messages)
            stats.precomputeAggregates()
            let next = SessionParseCheckpoint(parserRevision: checkpointParserRevision,
                                               sources: [path: .init(snapshot: reader.snapshot, offset: reader.nextOffset)],
                                               state: try JSONEncoder().encode(state))
            return .init(stats: stats, quickStats: .init(messageCount: state.messages, userMessageCount: state.messages, totalTokens: state.tokens),
                         searchIndex: appending ? .update(upserting: messages, removing: []) : .replaceIdentified(messages),
                         checkpoint: next, bytesRead: reader.bytesRead)
        }
    }

    private var directory: URL!
    private var database: DatabaseService!
    private var file: URL { directory.appendingPathComponent("fixture.jsonl") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseService(databasePath: directory.appendingPathComponent("cache.db").path)
        database.open()
    }

    override func tearDownWithError() throws {
        database.close()
        database = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func parse(_ provider: FixtureProvider) async throws -> SessionParseOutcome {
        let session = try XCTUnwrap(provider.scanSessions().first)
        let cached = database.loadCached(provider: .claude, sessionIds: ["fixture"])["fixture"]
        return await SessionParseValidator.parse(provider: provider, session: session, quick: .init(), cached: cached, database: database)
    }

    private func commit(_ outcome: SessionParseOutcome, provider: FixtureProvider) throws {
        let session = try XCTUnwrap(provider.scanSessions().first)
        let request = try XCTUnwrap(outcome.saveRequest(for: session))
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [request]))
    }

    func testAppendAndDatabaseReopenKeepStatisticsAndSearchConsistent() async throws {
        try Data("{\"tokens\":10,\"text\":\"original message\"}\n".utf8).write(to: file)
        let provider = FixtureProvider(path: file.path)
        try commit(await parse(provider), provider: provider)
        database.close()
        database.open()
        let addition = "{\"tokens\":5,\"text\":\"appended message\"}\n"
        try append(addition)
        let update = try await parse(provider)
        XCTAssertEqual(update.committedStats?.totalTokens, 15)
        XCTAssertEqual(update.checkpointUpdate?.bytesRead, Int64(addition.utf8.count))
        try commit(update, provider: provider)
        XCTAssertEqual(database.search(query: "original", provider: .claude).count, 1)
        XCTAssertEqual(database.search(query: "appended", provider: .claude).count, 1)
        let unchanged = try await parse(provider)
        XCTAssertNil(unchanged.committedStats)
        XCTAssertFalse(unchanged.shouldRetry)
        XCTAssertEqual(unchanged.displayStats?.totalTokens, 15)
    }

    func testUncommittedParseCanBeReplayedWithoutDoubleCounting() async throws {
        try Data("{\"tokens\":10,\"text\":\"original message\"}\n".utf8).write(to: file)
        let provider = FixtureProvider(path: file.path)
        try commit(await parse(provider), provider: provider)
        try append("{\"tokens\":5,\"text\":\"appended message\"}\n")
        let interrupted = try await parse(provider) // Simulated crash before COMMIT.
        let retried = try await parse(provider)
        XCTAssertEqual(interrupted.committedStats?.totalTokens, retried.committedStats?.totalTokens)
        try commit(retried, provider: provider)
        XCTAssertEqual(database.loadAllCached(provider: .claude)["fixture"]?.sessionStats?.totalTokens, 15)
        let session = try XCTUnwrap(provider.scanSessions().first)
        let stale = try XCTUnwrap(interrupted.saveRequest(for: session))
        XCTAssertFalse(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [stale]))
    }

    func testSameSizeReplacementRebuildsInsteadOfAppending() async throws {
        try Data("{\"tokens\":10,\"text\":\"original\"}\n".utf8).write(to: file)
        let provider = FixtureProvider(path: file.path)
        try commit(await parse(provider), provider: provider)
        try Data("{\"tokens\":20,\"text\":\"replaced\"}\n".utf8).write(to: file, options: .atomic)
        let update = try await parse(provider)
        XCTAssertEqual(update.committedStats?.totalTokens, 20)
        try commit(update, provider: provider)
        XCTAssertTrue(database.search(query: "original", provider: .claude).isEmpty)
        XCTAssertEqual(database.search(query: "replaced", provider: .claude).count, 1)
    }

    func testUnchangedCheckpointWithStaleIndexForcesProjectionRebuild() async throws {
        try Data("{\"tokens\":10,\"text\":\"original message\"}\n".utf8).write(to: file)
        let provider = FixtureProvider(path: file.path)
        let first = try await parse(provider)
        try commit(first, provider: provider)
        let checkpoint = try XCTUnwrap(first.checkpointUpdate?.checkpoint)
        // Simulate a retained parser cursor whose search projection is stale.
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [
            .init(sessionId: "fixture", fileSize: 0, mtime: .distantPast,
                  stats: try XCTUnwrap(first.committedStats), searchIndexUpdate: .preserve, checkpoint: checkpoint)
        ]))
        XCTAssertFalse(database.hasCompleteIndex(provider: .claude, sessionId: "fixture"))
        let repaired = try await parse(provider)
        XCTAssertNotNil(repaired.committedStats)
        try commit(repaired, provider: provider)
        XCTAssertTrue(database.hasCompleteIndex(provider: .claude, sessionId: "fixture"))
        XCTAssertEqual(database.search(query: "original", provider: .claude).count, 1)
    }

    func testStoreStartupUsesCapabilityAndRestoresCheckpoint() async throws {
        try Data("{\"tokens\":10,\"text\":\"original message\"}\n".utf8).write(to: file)
        let provider = FixtureProvider(path: file.path)
        for expected in [10, 15] {
            if expected == 15 { try append("{\"tokens\":5,\"text\":\"appended message\"}\n") }
            let store = SessionDataStore(kind: .claude, provider: provider, database: database)
            let completed = expectation(description: "store startup completed")
            let subscription = store.$isFullParseComplete.filter { $0 }.prefix(1).sink { _ in completed.fulfill() }
            store.start()
            await fulfillment(of: [completed], timeout: 5)
            XCTAssertEqual(store.parsedStats["fixture"]?.totalTokens, expected)
            XCTAssertNotNil(database.loadParseCheckpoint(provider: .claude, sessionId: "fixture"))
            subscription.cancel()
            store.stop()
            database.close()
            database.open()
        }
    }
}
