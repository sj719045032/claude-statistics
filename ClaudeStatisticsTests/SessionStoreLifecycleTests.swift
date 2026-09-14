import XCTest
import Combine
import ClaudeStatisticsKit

@testable import Claude_Statistics

@MainActor
final class SessionStoreLifecycleTests: XCTestCase {
    private final class Watcher: SessionWatcher {
        var onChange: ((Set<String>) -> Void)?
        var started = false
        func start() { started = true }
        func stop() { started = false }
        func send(_ paths: Set<String>) { if started { onChange?(paths) } }
    }

    /// No credentials, hooks, usage calls, or user's filesystem are touched.
    private final class Provider: SessionProvider, @unchecked Sendable {
        let providerId = "claude"
        let displayName = "Fixture"
        let capabilities = ProviderCapabilities.claude
        let configDirectory = ""
        let usageSource: (any ProviderUsageSource)? = nil
        let scan: @Sendable () -> [Session]
        let watcher = Watcher()
        var parseQuick: @Sendable (String) -> SessionQuickStats = { _ in SessionQuickStats() }
        var parseFull: @Sendable (String) -> SessionStats = { _ in SessionStats() }
        var parseIndex: @Sendable (String) -> [SearchIndexMessage] = { _ in [] }
        var rescanDecision: @Sendable (Set<String>) -> Bool = { _ in false }

        init(scan: @escaping @Sendable () -> [Session] = { [] }) { self.scan = scan }
        func scanSessions() -> [Session] { scan() }
        func resolvedProjectPath(for session: Session) -> String { session.projectPath }
        func makeWatcher(onChange: @escaping (Set<String>) -> Void) -> (any SessionWatcher)? {
            watcher.onChange = onChange
            return watcher
        }
        func shouldRescanSessions(for changedPaths: Set<String>) -> Bool { rescanDecision(changedPaths) }
        func parseQuickStats(at path: String) -> SessionQuickStats { parseQuick(path) }
        func parseSession(at path: String) -> SessionStats { parseFull(path) }
        func parseSessionIncremental(fromData: Data, fromOffset: Int64, existingStats: SessionStats,
                                     path: String) -> IncrementalParseResult? {
            XCTFail("Host must not load the whole file to probe the legacy stats-only API")
            return nil
        }
        func parseMessages(at path: String) -> [TranscriptDisplayMessage] { [] }
        func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] { parseIndex(path) }
        func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] { [] }
        func openNewSession(_ session: Session) {}
        func resumeSession(_ session: Session) {}
        func openNewSession(inDirectory path: String) {}
        func resumeCommand(for session: Session) -> String { "" }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// A provider may read its own state to decide whether a watcher batch
    /// needs a full scan — Codex reads its thread table on every WAL event. The
    /// store must ask off the main actor, do nothing on "no" for a batch that
    /// names no session, and rescan on "yes".
    func testRescanDecisionRunsOffTheMainActor() async {
        let scans = Counter()
        let decisions = Counter()
        let firstDecision = expectation(description: "first rescan decision")
        let secondDecision = expectation(description: "second rescan decision")
        let rescanned = expectation(description: "rescan ran")
        let provider = Provider {
            if scans.increment() == 2 { rescanned.fulfill() }
            return []
        }
        provider.rescanDecision = { paths in
            XCTAssertFalse(Thread.isMainThread, "the rescan decision must not run on the main actor")
            XCTAssertEqual(paths, ["/fixture/state.db-wal"])
            let call = decisions.increment()
            if call == 1 {
                firstDecision.fulfill()
                return false
            }
            XCTAssertEqual(scans.value, 1, "a \"no\" answer must not scan")
            secondDecision.fulfill()
            return true
        }
        let database = DatabaseService(databasePath: ":memory:")
        let store = SessionDataStore(kind: .claude, provider: provider, database: database)
        let loaded = expectation(description: "initial load finished")
        let subscription = store.$isFullParseComplete.filter { $0 }.first().sink { _ in loaded.fulfill() }
        store.start()
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(scans.value, 1)

        provider.watcher.send(["/fixture/state.db-wal"])
        await fulfillment(of: [firstDecision], timeout: 5)
        provider.watcher.send(["/fixture/state.db-wal"])
        await fulfillment(of: [secondDecision, rescanned], timeout: 5)
        XCTAssertEqual(scans.value, 2)

        subscription.cancel()
        store.stop()
        database.close()
    }

    func testStoppedStoreRejectsLateScannerResult() async {
        let entered = expectation(description: "scanner entered")
        let returned = expectation(description: "scanner returned")
        let unexpected = expectation(description: "stale sessions published")
        unexpected.isInverted = true
        let gate = DispatchSemaphore(value: 0)
        let session = Session(id: "late", externalID: "late", provider: "claude", projectPath: "/fixture",
                              filePath: "", startTime: nil, lastModified: .distantPast, fileSize: 0)
        let provider = Provider {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 2)
            returned.fulfill()
            return [session]
        }
        let database = DatabaseService(databasePath: ":memory:")
        let store = SessionDataStore(kind: .claude, provider: provider, database: database)
        let subscription = store.$sessions.dropFirst().sink { _ in unexpected.fulfill() }
        store.start()
        await fulfillment(of: [entered], timeout: 2)
        store.stop()
        gate.signal()
        await fulfillment(of: [returned], timeout: 2)
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(database.loadAllCached(provider: .claude).isEmpty)
        subscription.cancel()
        database.close()
    }

    func testStoppingOneStoreLeavesSharedDatabaseUsable() {
        let database = DatabaseService(databasePath: ":memory:")
        database.open()
        let store = SessionDataStore(kind: .claude, provider: Provider(), database: database)
        store.stop()
        let request = DatabaseService.SaveSessionStatsRequest(
            sessionId: "gemini-session", fileSize: 10, mtime: .distantPast,
            stats: SessionStats(), searchMessages: []
        )
        XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .gemini, requests: [request]))
        XCTAssertEqual(database.loadAllCached(provider: .gemini).count, 1)
        database.close()
    }

    func testHiddenStoreDefersAggregationUntilOpened() async {
        let store = SessionDataStore(kind: .claude, provider: Provider(),
                                     database: DatabaseService(databasePath: ":memory:"))
        var stats = SessionStats()
        var slice = DaySlice()
        slice.totalInputTokens = 123
        stats.fiveMinSlices[Date(timeIntervalSince1970: 1_000)] = slice
        stats.precomputeAggregates()
        store.parsedStats = ["fixture": stats]
        store.selectedPeriod = .all
        XCTAssertEqual(store.allTimeTokens, 0)

        let finished = expectation(description: "visible aggregate published")
        let subscription = store.$allTimeTokens.dropFirst().sink { value in
            if value == 123 { finished.fulfill() }
        }
        store.popoverDidOpen()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(store.allTimeTokens, 123)
        subscription.cancel()
        store.popoverDidClose()
        store.stop()
    }

    private func repairFixture(count: Int, database: DatabaseService) throws -> (URL, [Session]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sessions: [Session] = []
        database.open()
        for index in 0..<count {
            let path = directory.appendingPathComponent("s\(index).jsonl").path
            try Data("fixture".utf8).write(to: URL(fileURLWithPath: path))
            let file = try TranscriptFileSnapshot.read(at: path)
            let id = "s\(index)"
            sessions.append(Session(id: id, externalID: id, provider: "claude", projectPath: "/fixture",
                                    filePath: path, startTime: nil, lastModified: file.modifiedAt, fileSize: file.size))
            XCTAssertTrue(database.saveSessionsStatsAndIndexes(provider: .claude, requests: [
                .init(sessionId: id, fileSize: file.size, mtime: file.modifiedAt,
                      stats: SessionStats(), searchIndexUpdate: .preserve)
            ]))
        }
        return (directory, sessions)
    }

    func testIndexRepairCommitsEachSessionBeforeParsingTheNext() async throws {
        let database = DatabaseService(databasePath: ":memory:")
        let (directory, sessions) = try repairFixture(count: 3, database: database)
        defer { database.close(); try? FileManager.default.removeItem(at: directory) }
        let provider = Provider()
        provider.parseIndex = { path in
            if path.hasSuffix("s1.jsonl") { XCTAssertTrue(database.hasCompleteIndex(provider: .claude, sessionId: "s0")) }
            if path.hasSuffix("s2.jsonl") { XCTAssertTrue(database.hasCompleteIndex(provider: .claude, sessionId: "s1")) }
            return [SearchIndexMessage(role: "user", content: "repairneedle", timestamp: nil)]
        }
        await SessionDataStore.repairSearchIndexes(provider: provider, db: database, for: sessions,
                                                   cache: database.loadAllCached(provider: .claude), scheduler: BackgroundWorkScheduler())
        XCTAssertEqual(database.sessionsWithCompleteIndex(provider: .claude), Set(sessions.map(\.id)))
        XCTAssertEqual(database.search(query: "repairneedle", provider: .claude).count, 3)
    }

    func testCancelledIndexRepairDoesNotCommitOrParseNextSession() async throws {
        let database = DatabaseService(databasePath: ":memory:")
        let (directory, sessions) = try repairFixture(count: 2, database: database)
        defer { database.close(); try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "first index parser started")
        let gate = DispatchSemaphore(value: 0)
        let provider = Provider()
        provider.parseIndex = { path in
            XCTAssertTrue(path.hasSuffix("s0.jsonl"), "Cancellation must prevent the next session from being parsed")
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return [SearchIndexMessage(role: "user", content: "cancelledneedle", timestamp: nil)]
        }
        let cache = database.loadAllCached(provider: .claude)
        let task = Task.detached {
            await SessionDataStore.repairSearchIndexes(provider: provider, db: database, for: sessions,
                                                       cache: cache, scheduler: BackgroundWorkScheduler())
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        gate.signal()
        await task.value
        XCTAssertTrue(database.sessionsWithCompleteIndex(provider: .claude).isEmpty)
        XCTAssertTrue(database.search(query: "cancelledneedle", provider: .claude).isEmpty)
    }

    func testIndexRepairRejectsFileReplacementDuringParsing() async throws {
        let database = DatabaseService(databasePath: ":memory:")
        let (directory, sessions) = try repairFixture(count: 1, database: database)
        defer { database.close(); try? FileManager.default.removeItem(at: directory) }
        let provider = Provider()
        provider.parseIndex = { path in
            try? Data("replacement".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            return [SearchIndexMessage(role: "user", content: "oldneedle", timestamp: nil)]
        }
        await SessionDataStore.repairSearchIndexes(provider: provider, db: database, for: sessions,
                                                   cache: database.loadAllCached(provider: .claude), scheduler: BackgroundWorkScheduler())
        XCTAssertFalse(database.hasCompleteIndex(provider: .claude, sessionId: "s0"))
        XCTAssertTrue(database.search(query: "oldneedle", provider: .claude).isEmpty)
    }

    func testStartupCommitsParsedSessionBeforeParsingTheNext() async throws {
        let database = DatabaseService(databasePath: ":memory:")
        let (directory, sessions) = try repairFixture(count: 3, database: database)
        defer { database.close(); try? FileManager.default.removeItem(at: directory) }
        database.invalidateSessionParseCaches(provider: .claude, sessionIds: Set(sessions.map(\.id)))
        // Scanner output is sorted by last activity, not its input array order.
        let ordered = sessions.enumerated().map { index, session in
            Session(id: session.id, externalID: session.externalID, provider: session.provider,
                    projectPath: session.projectPath, filePath: session.filePath, startTime: nil,
                    lastModified: Date(timeIntervalSince1970: Double(index)), fileSize: session.fileSize)
        }
        let provider = Provider { ordered }
        provider.parseFull = { path in
            if path.hasSuffix("s1.jsonl") { XCTAssertTrue(database.hasCompleteIndex(provider: .claude, sessionId: "s2")) }
            if path.hasSuffix("s0.jsonl") { XCTAssertTrue(database.hasCompleteIndex(provider: .claude, sessionId: "s1")) }
            return SessionStats()
        }
        provider.parseIndex = { _ in [SearchIndexMessage(role: "user", content: "startupneedle", timestamp: nil)] }
        let store = SessionDataStore(kind: .claude, provider: provider, database: database, scheduler: BackgroundWorkScheduler())
        defer { store.stop() }
        let finished = expectation(description: "startup completed")
        let subscription = store.$isFullParseComplete.filter { $0 }.prefix(1).sink { _ in finished.fulfill() }
        defer { subscription.cancel() }
        store.start()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(database.search(query: "startupneedle", provider: .claude).count, 3)
        XCTAssertEqual(store.parsedStats.count, 3)
    }

    func testLegacyAppendRefreshesSearchIndexThroughActualWatcherPath() async throws {
        let database = DatabaseService(databasePath: ":memory:")
        let (directory, sessions) = try repairFixture(count: 1, database: database)
        defer { database.close(); try? FileManager.default.removeItem(at: directory) }
        database.invalidateSessionParseCaches(provider: .claude, sessionIds: Set(sessions.map(\.id)))
        let provider = Provider { sessions }
        provider.parseQuick = { path in
            var quick = SessionQuickStats()
            quick.topic = try? String(contentsOfFile: path)
            return quick
        }
        provider.parseIndex = { path in
            [SearchIndexMessage(role: "user", content: (try? String(contentsOfFile: path)) ?? "", timestamp: nil)]
        }
        let store = SessionDataStore(kind: .claude, provider: provider, database: database, scheduler: BackgroundWorkScheduler())
        defer { store.stop() }
        let loaded = expectation(description: "cache and initial index ready")
        let initialSubscription = store.$isFullParseComplete.filter { $0 }.prefix(1).sink { _ in loaded.fulfill() }
        store.start()
        await fulfillment(of: [loaded], timeout: 3)
        initialSubscription.cancel()
        XCTAssertEqual(database.search(query: "fixture", provider: .claude).count, 1)

        let updated = expectation(description: "append committed and published")
        let subscription = store.$parsedStatsVersion.dropFirst().prefix(1).sink { _ in updated.fulfill() }
        defer { subscription.cancel() }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: sessions[0].filePath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" appendedneedle".utf8))
        try handle.close()
        provider.watcher.send([sessions[0].filePath])
        await fulfillment(of: [updated], timeout: 3)
        XCTAssertEqual(database.search(query: "appendedneedle", provider: .claude).count, 1)
        XCTAssertEqual(database.search(query: "fixture", provider: .claude).count, 1)
        XCTAssertTrue(database.hasCompleteIndex(provider: .claude, sessionId: sessions[0].id))
        XCTAssertEqual(database.loadAllCached(provider: .claude)[sessions[0].id]?.quickStats?.topic,
                       "fixture appendedneedle")
    }

    func testLegacyParserReplacementCannotCommitMixedStatsAndIndex() async throws {
        let database = DatabaseService(databasePath: ":memory:")
        let (directory, sessions) = try repairFixture(count: 1, database: database)
        defer { database.close(); try? FileManager.default.removeItem(at: directory) }
        let provider = Provider()
        provider.parseIndex = { path in
            try? Data("replacement".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            return [SearchIndexMessage(role: "user", content: "mixedneedle", timestamp: nil)]
        }
        let outcome = await SessionParseValidator.parseAndCommit(
            provider: provider, session: sessions[0], quick: .init(),
            cached: database.loadAllCached(provider: .claude)[sessions[0].id], database: database,
            scheduler: BackgroundWorkScheduler()
        )
        XCTAssertNil(outcome.stats)
        XCTAssertTrue(outcome.shouldRetry)
        XCTAssertTrue(database.search(query: "mixedneedle", provider: .claude).isEmpty)
    }

    func testCancelledLegacyParserCannotCommitAfterReturning() async throws {
        let database = DatabaseService(databasePath: ":memory:")
        let (directory, sessions) = try repairFixture(count: 1, database: database)
        defer { database.close(); try? FileManager.default.removeItem(at: directory) }
        let provider = Provider()
        let started = expectation(description: "legacy parser started")
        let gate = DispatchSemaphore(value: 0)
        provider.parseIndex = { _ in
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return [SearchIndexMessage(role: "user", content: "latecommitneedle", timestamp: nil)]
        }
        let cached = database.loadAllCached(provider: .claude)[sessions[0].id]
        let task = Task {
            await SessionParseValidator.parseAndCommit(
                provider: provider, session: sessions[0], quick: .init(), cached: cached,
                database: database, scheduler: BackgroundWorkScheduler()
            )
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        gate.signal()
        let result = await task.value
        XCTAssertNil(result.stats)
        XCTAssertFalse(result.shouldRetry)
        XCTAssertTrue(database.search(query: "latecommitneedle", provider: .claude).isEmpty)
    }
}
