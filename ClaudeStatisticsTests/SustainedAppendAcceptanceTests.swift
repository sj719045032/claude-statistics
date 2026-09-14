import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Acceptance gate "sustained multi-session append workload: bounded queue,
/// returns to idle after draining", at the store level: the real Claude
/// checkpoint parser over several transcripts, the real `SessionDataStore`,
/// database and scheduler, driven by a watcher the test controls. It uses temp
/// files, not the user's ~/.claude, so it measures the pipeline rather than the
/// whole app. Skipped unless `TEST_RUNNER_CLAUDE_STATS_ACCEPTANCE=1`.
@MainActor
final class SustainedAppendAcceptanceTests: XCTestCase {
    private final class Watcher: SessionWatcher {
        var onChange: ((Set<String>) -> Void)?
        var started = false
        func start() { started = true }
        func stop() { started = false }
        func send(_ paths: Set<String>) { if started { onChange?(paths) } }
    }

    /// Time spent inside the provider's parse, from whichever thread runs it.
    private final class ParseMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0.0
        private var count = 0
        func add(_ seconds: Double) { lock.lock(); total += seconds; count += 1; lock.unlock() }
        func reset() { lock.lock(); total = 0; count = 0; lock.unlock() }
        var seconds: Double { lock.lock(); defer { lock.unlock() }; return total }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private final class Provider: SessionProvider, CheckpointedSessionDataProvider, @unchecked Sendable {
        let providerId = "claude"
        let displayName = "Sustained append fixture"
        let capabilities = ProviderCapabilities.claude
        let configDirectory: String
        let usageSource: (any ProviderUsageSource)? = nil
        let paths: [String]
        let watcher = Watcher()
        let meter: ParseMeter
        var checkpointParserRevision: String { ClaudeCheckpointParser.revision }

        init(paths: [String], meter: ParseMeter) {
            self.paths = paths
            self.meter = meter
            configDirectory = ((paths.first ?? "/") as NSString).deletingLastPathComponent
        }

        func scanSessions() -> [Session] {
            paths.compactMap { path in
                guard let snapshot = try? TranscriptFileSnapshot.read(at: path) else { return nil }
                let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                return Session(id: id, externalID: id, provider: providerId, projectPath: configDirectory,
                               filePath: path, startTime: nil, lastModified: snapshot.modifiedAt, fileSize: snapshot.size)
            }
        }
        func resolvedProjectPath(for session: Session) -> String { session.projectPath }
        func makeWatcher(onChange: @escaping (Set<String>) -> Void) -> (any SessionWatcher)? {
            watcher.onChange = onChange
            return watcher
        }
        func parseQuickStats(at path: String) -> SessionQuickStats { SessionQuickStats() }
        func parseSession(at path: String) -> SessionStats { SessionStats() }
        func parseMessages(at path: String) -> [TranscriptDisplayMessage] { [] }
        func parseSearchIndexMessages(at path: String) -> [SearchIndexMessage] { [] }
        func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] { [] }
        func openNewSession(_ session: Session) {}
        func resumeSession(_ session: Session) {}
        func openNewSession(inDirectory path: String) {}
        func resumeCommand(for session: Session) -> String { "" }

        func parseSessionUpdate(at path: String, checkpoint: SessionParseCheckpoint?) throws -> CheckpointedSessionUpdate? {
            let start = CFAbsoluteTimeGetCurrent()
            defer { meter.add(CFAbsoluteTimeGetCurrent() - start) }
            return try ClaudeCheckpointParser.parse(at: path, checkpoint: checkpoint)
        }
    }

    private func record(session: Int, index: Int, text: Int = 2_000) -> Data {
        let entry: [String: Any] = [
            "type": "assistant", "timestamp": "2026-09-11T01:00:00Z",
            "message": ["id": "s\(session)-m\(index)", "model": "claude-sonnet-4-6",
                        "content": [["type": "text", "text": String(repeating: "y", count: text)]],
                        "usage": ["input_tokens": 10, "output_tokens": 5]],
        ]
        var data = try! JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    func testSustainedMultiSessionAppendsStayCorrectAndDrain() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDE_STATS_ACCEPTANCE"] == "1" else {
            throw XCTSkip("set CLAUDE_STATS_ACCEPTANCE=1")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SustainedAppend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessions = 4
        let historyRecords = 1_000          // ~2 MB of history per session
        let ticks = 200                     // 20 s at 100 ms
        let paths = (0..<sessions).map { directory.appendingPathComponent("session-\($0).jsonl").path }
        for (session, path) in paths.enumerated() {
            var history = Data()
            for index in 0..<historyRecords { history.append(record(session: session, index: index)) }
            try history.write(to: URL(fileURLWithPath: path))
        }

        let database = DatabaseService(databasePath: directory.appendingPathComponent("sustained.db").path)
        let meter = ParseMeter()
        let provider = Provider(paths: paths, meter: meter)
        let store = SessionDataStore(kind: .claude, provider: provider, database: database,
                                     scheduler: BackgroundWorkScheduler(concurrency: 2))
        let loaded = expectation(description: "initial load")
        let subscription = store.$isFullParseComplete.filter { $0 }.first().sink { _ in loaded.fulfill() }
        store.start()
        await fulfillment(of: [loaded], timeout: 60)
        subscription.cancel()

        // Main-thread responsiveness while the pipeline works.
        var maxStall = 0.0
        let heartbeat = Task { @MainActor in
            var last = CFAbsoluteTimeGetCurrent()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
                let now = CFAbsoluteTimeGetCurrent()
                maxStall = max(maxStall, now - last - 0.010)
                last = now
            }
        }

        meter.reset()
        var appended: Int64 = 0
        let windowStart = CFAbsoluteTimeGetCurrent()
        for tick in 0..<ticks {
            for (session, path) in paths.enumerated() {
                let data = record(session: session, index: historyRecords + tick)
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
                appended += Int64(data.count)
            }
            provider.watcher.send(Set(paths))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let lastWrite = CFAbsoluteTimeGetCurrent()
        let window = lastWrite - windowStart

        // Drained: every session's committed total includes every append.
        let expected = (historyRecords + ticks) * 15
        let ids = paths.map { ((($0 as NSString).lastPathComponent) as NSString).deletingPathExtension }
        var drained = false
        while CFAbsoluteTimeGetCurrent() - lastWrite < 30 {
            if ids.allSatisfy({ store.parsedStats[$0]?.totalTokens == expected }) { drained = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let drain = CFAbsoluteTimeGetCurrent() - lastWrite
        heartbeat.cancel()
        store.stop()
        database.close()

        print("[sustained] sessions=\(sessions) appends=\(sessions * ticks) appended_bytes=\(appended) " +
              "window_s=\(String(format: "%.1f", window)) parse_work_s=\(String(format: "%.2f", meter.seconds)) " +
              "utilization=\(String(format: "%.1f", 100 * meter.seconds / window))% parse_calls=\(meter.calls) " +
              "drain_ms=\(String(format: "%.0f", drain * 1000)) max_main_stall_ms=\(String(format: "%.1f", maxStall * 1000))")
        XCTAssertTrue(drained, "every append must be committed")
        XCTAssertLessThan(drain, 5, "the queue returns to idle shortly after writes stop")
        XCTAssertLessThan(maxStall, 0.1, "no main-thread stall over 100 ms")
    }
}
