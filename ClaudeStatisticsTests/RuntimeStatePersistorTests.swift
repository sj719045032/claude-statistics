import Foundation
import XCTest

@testable import Claude_Statistics

@MainActor
final class RuntimeStatePersistorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RuntimeStatePersistorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func tempFileURL(_ name: String = "runtime.json") -> URL {
        tempDir.appendingPathComponent(name)
    }

    private func makeSession(
        provider: ProviderKind,
        sessionId: String,
        lastActivityAt: Date,
        projectPath: String? = nil,
        pid: Int32? = nil,
        currentActivity: String? = nil
    ) -> RuntimeSession {
        // Build the session via Codable rather than the synthesized memberwise
        // init — many of RuntimeSession's stored properties have no inline
        // default, so the memberwise init takes 30+ args and would be brittle
        // as the struct grows. Going through JSONDecoder lets us specify only
        // the fields we care about; everything else takes its declared default.
        // We use the default `.deferredToDate` date strategy (raw numeric
        // timeIntervalSinceReferenceDate) so the decoder matches what
        // `JSONEncoder().encode` produces — i.e. the same format the
        // persistor itself uses on disk.
        var json: [String: Any] = [
            "provider": provider.rawValue,
            "sessionId": sessionId,
            "lastActivityAt": lastActivityAt.timeIntervalSinceReferenceDate,
            // Swift's synthesized Decodable does not honor inline defaults for
            // non-optional fields, so each non-Optional stored property
            // without an Optional type must be supplied here, even if the
            // declaration in RuntimeSession has `= ...`.
            "status": "idle",
            "backgroundShellCount": 0,
            "activeSubagentCount": 0,
            "activeTools": [String: Any](),
            "recentlyCompletedTools": [Any]()
        ]
        if let projectPath { json["projectPath"] = projectPath }
        if let pid { json["pid"] = Int(pid) }
        if let currentActivity { json["currentActivity"] = currentActivity }

        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(RuntimeSession.self, from: data)
    }

    private func writeRawJSON(_ dict: [String: RuntimeSession], to url: URL) throws {
        let data = try JSONEncoder().encode(dict)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Round-trip

    func test_flushWriteThenLoad_roundtripsSingleSession() throws {
        let url = tempFileURL()
        let persistor = RuntimeStatePersistor(fileURL: url)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = makeSession(
            provider: .codex,
            sessionId: "abc-123",
            lastActivityAt: now,
            projectPath: "/tmp/proj"
        )
        let snapshot: [String: RuntimeSession] = ["codex:abc-123": session]

        persistor.flushWrite(snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "flushWrite produces a file on disk")

        let loaded = try XCTUnwrap(persistor.load(), "load returns the dict that was just written")
        XCTAssertEqual(loaded.count, 1)
        let entry = try XCTUnwrap(loaded["codex:abc-123"])
        XCTAssertEqual(entry.sessionId, "abc-123")
        XCTAssertEqual(entry.projectPath, "/tmp/proj")
        XCTAssertEqual(entry.lastActivityAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_flushWriteThenLoad_roundtripsMultipleProviders() throws {
        let url = tempFileURL()
        let persistor = RuntimeStatePersistor(fileURL: url)

        let now = Date(timeIntervalSince1970: 1_700_000_500)
        let claude = makeSession(provider: .claude, sessionId: "c1", lastActivityAt: now, projectPath: "/c")
        let codex = makeSession(provider: .codex, sessionId: "x1", lastActivityAt: now, projectPath: "/x")
        let gemini = makeSession(provider: .gemini, sessionId: "g1", lastActivityAt: now, projectPath: "/g")
        let snapshot: [String: RuntimeSession] = [
            "claude:c1": claude,
            "codex:x1": codex,
            "gemini:g1": gemini
        ]

        persistor.flushWrite(snapshot)
        let loaded = persistor.load()

        XCTAssertEqual(loaded?.count, 3, "all three provider entries survive round-trip")
        XCTAssertEqual(loaded?["claude:c1"]?.projectPath, "/c")
        XCTAssertEqual(loaded?["codex:x1"]?.projectPath, "/x")
        XCTAssertEqual(loaded?["gemini:g1"]?.projectPath, "/g")
    }

    // MARK: - load() boundary cases

    func test_load_returnsNilForMissingFile() {
        let url = tempFileURL("does-not-exist.json")
        let persistor = RuntimeStatePersistor(fileURL: url)
        XCTAssertNil(persistor.load(), "missing file yields nil rather than throwing")
    }

    func test_load_returnsNilForCorruptJSON() throws {
        let url = tempFileURL()
        try Data("not json at all".utf8).write(to: url, options: .atomic)
        let persistor = RuntimeStatePersistor(fileURL: url)
        XCTAssertNil(persistor.load(), "garbage JSON decodes as nil, not as throw")
    }

    func test_load_returnsEmptyDictForEmptyJSONObject() throws {
        let url = tempFileURL()
        try Data("{}".utf8).write(to: url, options: .atomic)
        let persistor = RuntimeStatePersistor(fileURL: url)
        let loaded = persistor.load()
        XCTAssertEqual(loaded?.count, 0, "empty object decodes to empty dict, not nil")
    }

    // MARK: - normalize: canonical Claude session ID

    func test_load_normalizesClaudeParentChildSessionId() throws {
        let url = tempFileURL()
        let now = Date(timeIntervalSince1970: 1_700_001_000)
        // Disk-side key uses the parent::child form. After normalize, the
        // session's sessionId should be the trailing segment and the dict
        // should be re-keyed to the canonical form.
        let session = makeSession(
            provider: .claude,
            sessionId: "projects/foo::abc-123",
            lastActivityAt: now,
            projectPath: "/foo"
        )
        try writeRawJSON(["claude:projects/foo::abc-123": session], to: url)

        let persistor = RuntimeStatePersistor(fileURL: url)
        let loaded = persistor.load()

        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?["claude:projects/foo::abc-123"], "raw parent::child key is dropped")
        XCTAssertEqual(loaded?["claude:abc-123"]?.sessionId, "abc-123", "sessionId is rewritten to trailing segment")
        XCTAssertEqual(loaded?["claude:abc-123"]?.projectPath, "/foo")
    }

    func test_load_doesNotNormalizeNonClaudeProvider() throws {
        let url = tempFileURL()
        let now = Date(timeIntervalSince1970: 1_700_001_500)
        // Codex sessionIds containing :: are passed through unchanged.
        let session = makeSession(
            provider: .codex,
            sessionId: "ws::abc-123",
            lastActivityAt: now
        )
        try writeRawJSON(["codex:ws::abc-123": session], to: url)

        let persistor = RuntimeStatePersistor(fileURL: url)
        let loaded = persistor.load()

        XCTAssertEqual(loaded?["codex:ws::abc-123"]?.sessionId, "ws::abc-123", "non-Claude :: sessionIds are untouched")
        XCTAssertNil(loaded?["codex:abc-123"], "no canonicalisation for codex")
    }

    func test_load_claudeSessionIdWithoutDoubleColonStaysUnchanged() throws {
        let url = tempFileURL()
        let now = Date(timeIntervalSince1970: 1_700_001_700)
        let session = makeSession(provider: .claude, sessionId: "plain-id", lastActivityAt: now)
        try writeRawJSON(["claude:plain-id": session], to: url)

        let loaded = RuntimeStatePersistor(fileURL: url).load()
        XCTAssertEqual(loaded?["claude:plain-id"]?.sessionId, "plain-id", "no :: means no rewrite")
    }

    // MARK: - normalize: same-key arbitration via preferred

    func test_load_sameKey_newerLastActivityWins() throws {
        let url = tempFileURL()
        let older = Date(timeIntervalSince1970: 1_700_002_000)
        let newer = older.addingTimeInterval(10)

        // Both entries normalize to "claude:abc-123": the parent-prefixed form
        // and the bare form. Newer lastActivityAt should win regardless of
        // which one normalize sees first.
        let parentForm = makeSession(
            provider: .claude,
            sessionId: "projects/foo::abc-123",
            lastActivityAt: older,
            projectPath: "OLDER"
        )
        let bareForm = makeSession(
            provider: .claude,
            sessionId: "abc-123",
            lastActivityAt: newer,
            projectPath: "NEWER"
        )
        try writeRawJSON([
            "claude:projects/foo::abc-123": parentForm,
            "claude:abc-123": bareForm
        ], to: url)

        let loaded = RuntimeStatePersistor(fileURL: url).load()

        XCTAssertEqual(loaded?.count, 1, "duplicate-after-normalize keys collapse to one entry")
        XCTAssertEqual(loaded?["claude:abc-123"]?.projectPath, "NEWER", "newer lastActivityAt wins")
    }

    func test_load_sameKey_equalActivity_higherFocusSignalsWin() throws {
        let url = tempFileURL()
        let when = Date(timeIntervalSince1970: 1_700_003_000)

        // Equal lastActivityAt; one has pid set (focus signal +1) — that one
        // should win regardless of which normalize visits first.
        let withoutPid = makeSession(
            provider: .claude,
            sessionId: "projects/foo::dup-1",
            lastActivityAt: when,
            projectPath: "NO-PID",
            pid: nil
        )
        let withPid = makeSession(
            provider: .claude,
            sessionId: "dup-1",
            lastActivityAt: when,
            projectPath: "WITH-PID",
            pid: 4242
        )
        try writeRawJSON([
            "claude:projects/foo::dup-1": withoutPid,
            "claude:dup-1": withPid
        ], to: url)

        let loaded = RuntimeStatePersistor(fileURL: url).load()

        XCTAssertEqual(loaded?.count, 1)
        XCTAssertEqual(loaded?["claude:dup-1"]?.projectPath, "WITH-PID", "more focus signals (pid set) wins tie on lastActivityAt")
        XCTAssertEqual(loaded?["claude:dup-1"]?.pid, 4242)
    }

    func test_load_sameKey_equalActivityAndFocus_higherPayloadSignalsWin() throws {
        let url = tempFileURL()
        let when = Date(timeIntervalSince1970: 1_700_004_000)

        // Equal lastActivityAt, both pid==nil so focusSignalCount==0.
        // currentActivity adds a payload signal; that side should win.
        let plain = makeSession(
            provider: .claude,
            sessionId: "projects/bar::dup-2",
            lastActivityAt: when,
            projectPath: "PLAIN",
            currentActivity: nil
        )
        let withActivity = makeSession(
            provider: .claude,
            sessionId: "dup-2",
            lastActivityAt: when,
            projectPath: "WITH-ACTIVITY",
            currentActivity: "Editing main.swift"
        )
        try writeRawJSON([
            "claude:projects/bar::dup-2": plain,
            "claude:dup-2": withActivity
        ], to: url)

        let loaded = RuntimeStatePersistor(fileURL: url).load()

        XCTAssertEqual(loaded?.count, 1)
        XCTAssertEqual(loaded?["claude:dup-2"]?.projectPath, "WITH-ACTIVITY", "more payload signals wins tie on activity+focus")
        XCTAssertEqual(loaded?["claude:dup-2"]?.currentActivity, "Editing main.swift")
    }

    // MARK: - flushWrite cancels pending debounced write

    func test_scheduleWriteThenFlushWrite_endsWithFlushedSnapshot() throws {
        let url = tempFileURL()
        let persistor = RuntimeStatePersistor(fileURL: url)

        let early = makeSession(
            provider: .codex,
            sessionId: "s1",
            lastActivityAt: Date(timeIntervalSince1970: 1_700_005_000),
            projectPath: "EARLY"
        )
        let late = makeSession(
            provider: .codex,
            sessionId: "s1",
            lastActivityAt: Date(timeIntervalSince1970: 1_700_005_010),
            projectPath: "LATE"
        )

        persistor.scheduleWrite(["codex:s1": early])
        // flushWrite cancels the pending task and writes synchronously.
        persistor.flushWrite(["codex:s1": late])

        let loaded = persistor.load()
        XCTAssertEqual(loaded?["codex:s1"]?.projectPath, "LATE", "flushWrite supersedes the pending debounced write")
    }

    // MARK: - scheduleWrite eventually persists

    func test_scheduleWrite_eventuallyPersistsToDisk() throws {
        let url = tempFileURL()
        let persistor = RuntimeStatePersistor(fileURL: url)

        let session = makeSession(
            provider: .gemini,
            sessionId: "g-debounced",
            lastActivityAt: Date(timeIntervalSince1970: 1_700_006_000),
            projectPath: "DEBOUNCED"
        )

        persistor.scheduleWrite(["gemini:g-debounced": session])

        // Debounce interval is 0.4s; poll up to ~2s for the file to appear.
        let deadline = Date().addingTimeInterval(2.0)
        var loaded: [String: RuntimeSession]? = nil
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if FileManager.default.fileExists(atPath: url.path) {
                loaded = persistor.load()
                if loaded?["gemini:g-debounced"] != nil { break }
            }
        }

        XCTAssertEqual(loaded?["gemini:g-debounced"]?.projectPath, "DEBOUNCED", "scheduled write lands on disk after debounce")
    }
}
