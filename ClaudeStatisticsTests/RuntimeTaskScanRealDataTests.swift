import XCTest

@testable import Claude_Statistics

/// What one hook-driven task scan costs on this machine's largest real Claude
/// transcript: a scan from byte 0 (what a session without tasks paid on every
/// hook event) versus resuming at the recorded offset. Read-only. Skipped
/// unless `TEST_RUNNER_CLAUDE_STATS_REAL_DATA=1`.
final class RuntimeTaskScanRealDataTests: XCTestCase {
    func testResumingIsIndependentOfTranscriptLength() throws {
        guard ProcessInfo.processInfo.environment["CLAUDE_STATS_REAL_DATA"] == "1" else {
            throw XCTSkip("set CLAUDE_STATS_REAL_DATA=1")
        }
        let root = URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects"))
        let keys: [URLResourceKey] = [.fileSizeKey]
        var largest: (URL, Int)?
        for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) ?? .init()
        where url.pathExtension == "jsonl" {
            let size = (try? url.resourceValues(forKeys: Set(keys)).fileSize) ?? 0
            if size > (largest?.1 ?? 0) { largest = (url, size) }
        }
        let (url, size) = try XCTUnwrap(largest)

        var start = CFAbsoluteTimeGetCurrent()
        let full = RuntimeSessionEventApplier.taskScanResult(at: url.path, baseTasks: nil, fromOffset: nil)
        let fullSeconds = CFAbsoluteTimeGetCurrent() - start
        let offset = try XCTUnwrap(full?.nextOffset)

        start = CFAbsoluteTimeGetCurrent()
        _ = RuntimeSessionEventApplier.taskScanResult(at: url.path, baseTasks: nil, fromOffset: offset)
        let resumedSeconds = CFAbsoluteTimeGetCurrent() - start

        print("[task-scan] transcript_bytes=\(size) from_zero_ms=\(String(format: "%.1f", fullSeconds * 1000)) " +
              "resumed_ms=\(String(format: "%.2f", resumedSeconds * 1000))")
        XCTAssertLessThan(resumedSeconds, max(0.01, fullSeconds / 20))
    }
}
