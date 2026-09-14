import Foundation
import XCTest

@testable import Claude_Statistics

/// `taskScanResult` now streams the transcript a record at a time instead of
/// reading it whole. Full scans, incremental scans and a final record without a
/// newline must produce the task state the transcript describes.
final class RuntimeTaskScanTests: XCTestCase {
    private var directory: URL!
    private var path: String { directory.appendingPathComponent("transcript.jsonl").path }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeTaskScan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func reminder(_ tasks: [(String, String, String)], at time: String = "2026-09-11T01:00:00Z") -> [String: Any] {
        ["timestamp": time, "attachment": [
            "type": "task_reminder",
            "content": tasks.map { ["id": $0.0, "subject": $0.1, "status": $0.2] },
        ]]
    }

    private func update(_ id: String, _ status: String, at time: String = "2026-09-11T01:01:00Z") -> [String: Any] {
        ["timestamp": time, "message": ["content": [[
            "type": "tool_use", "name": "TaskUpdate", "input": ["taskId": id, "status": status],
        ]]]]
    }

    private func noise() -> [String: Any] {
        ["type": "assistant", "timestamp": "2026-09-11T01:00:30Z", "message": ["content": [["type": "text", "text": "ok"]]]]
    }

    private func records(_ values: [[String: Any]], finalNewline: Bool = true) throws -> Data {
        var data = Data()
        for (index, value) in values.enumerated() {
            data.append(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            if finalNewline || index < values.count - 1 { data.append(0x0A) }
        }
        return data
    }

    private func statuses(_ result: RuntimeTaskScanResult?) -> [String: String] {
        (result?.snapshot?.tasks ?? [:]).mapValues(\.status)
    }

    private func scan(baseTasks: [String: RuntimeTaskEntry]? = nil, fromOffset: UInt64? = nil) -> RuntimeTaskScanResult? {
        RuntimeSessionEventApplier.taskScanResult(at: path, baseTasks: baseTasks, fromOffset: fromOffset)
    }

    func testAFullScanAppliesUpdatesOverTheLatestReminder() throws {
        try records([reminder([("1", "Write code", "in_progress"), ("2", "Test it", "pending")]),
                     noise(), update("1", "completed")]).write(to: URL(fileURLWithPath: path))
        let result = scan()
        XCTAssertEqual(statuses(result), ["1": "completed", "2": "pending"])
        XCTAssertEqual(result?.nextOffset, UInt64(try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int))
        XCTAssertEqual(result?.clearsCurrentTask, false)
    }

    func testAnIncrementalScanReachesTheSameStateAsAFullOne() throws {
        let head = try records([reminder([("1", "Write code", "in_progress"), ("2", "Test it", "pending")]), noise()])
        try head.write(to: URL(fileURLWithPath: path))
        let first = try XCTUnwrap(scan())
        XCTAssertEqual(first.nextOffset, UInt64(head.count))

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: try records([update("2", "in_progress"), update("1", "completed")]))
        try handle.close()

        let incremental = scan(baseTasks: first.snapshot?.tasks, fromOffset: first.nextOffset)
        XCTAssertEqual(statuses(incremental), statuses(scan()))
        XCTAssertEqual(statuses(incremental), ["1": "completed", "2": "in_progress"])
    }

    /// The unterminated final record moves the only task from pending to in
    /// progress, so an active task remains and the snapshot survives; the test
    /// isolates final-line handling from the "all tasks done" clearing rule.
    func testAFinalRecordWithoutANewlineIsScanned() throws {
        try records([reminder([("1", "Write code", "pending")]), update("1", "in_progress")], finalNewline: false)
            .write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(statuses(scan()), ["1": "in_progress"])
    }

    func testAnEmptyReminderClearsTheCurrentTask() throws {
        try records([reminder([("1", "Write code", "in_progress")]), reminder([])]).write(to: URL(fileURLWithPath: path))
        let result = scan()
        XCTAssertNil(result?.snapshot)
        XCTAssertEqual(result?.clearsCurrentTask, true)
    }

    /// A session that has never used the task list must still resume from its
    /// last offset: hook events used to rescan it from byte 0 every time.
    func testASessionWithoutTasksResumesFromItsOffset() throws {
        // A reminder sits in the prefix. Resuming past it without base tasks
        // must not see it — proof the scan started at the offset.
        let head = try records([reminder([("1", "Old task", "in_progress")]), noise()])
        try head.write(to: URL(fileURLWithPath: path))
        let resumed = scan(baseTasks: nil, fromOffset: UInt64(head.count))
        XCTAssertNil(resumed?.snapshot, "the prefix was not re-read")
        XCTAssertEqual(resumed?.clearsCurrentTask, false)
        XCTAssertEqual(resumed?.nextOffset, UInt64(head.count))
    }

    func testResumingWithoutTasksSeesAReminderAppendedLater() throws {
        let head = try records([noise(), noise()])
        try head.write(to: URL(fileURLWithPath: path))
        let first = try XCTUnwrap(scan())
        XCTAssertNil(first.snapshot)

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: try records([reminder([("1", "New task", "in_progress")])]))
        try handle.close()

        let resumed = scan(baseTasks: nil, fromOffset: first.nextOffset)
        XCTAssertEqual(statuses(resumed), statuses(scan()))
        XCTAssertEqual(statuses(resumed), ["1": "in_progress"])
    }

    /// All tasks completed yields no snapshot, so the displayed tasks are
    /// cleared. Resuming with the result's carried `tasks` must still apply a
    /// later update that reopens one — exactly as a full scan does.
    func testResumingAfterEveryTaskCompletedKeepsTheTasks() throws {
        let head = try records([reminder([("1", "Write code", "completed"), ("2", "Test it", "completed")])])
        try head.write(to: URL(fileURLWithPath: path))
        let first = try XCTUnwrap(scan())
        XCTAssertNil(first.snapshot)
        XCTAssertEqual(first.tasks.mapValues(\.status), ["1": "completed", "2": "completed"])

        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: try records([update("2", "in_progress")]))
        try handle.close()

        let resumed = scan(baseTasks: first.tasks, fromOffset: first.nextOffset)
        XCTAssertEqual(statuses(resumed), statuses(scan()))
        XCTAssertEqual(statuses(resumed), ["1": "completed", "2": "in_progress"])
    }
}

