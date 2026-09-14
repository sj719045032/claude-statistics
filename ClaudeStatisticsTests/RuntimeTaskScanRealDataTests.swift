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
        let (url, size) = try XCTUnwrap(RealClaudeTranscripts.largest(1).first)

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
