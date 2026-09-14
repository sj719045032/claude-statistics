import Darwin
import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Every archive in this machine's database, streamed to a file by the writer
/// the transcript view now pages archived sessions from. Works on an APFS
/// clone of the live database; the original is never opened. Skipped unless
/// `TEST_RUNNER_CLAUDE_STATS_REAL_DATA=1`.
final class ArchivedTranscriptRealDataTests: XCTestCase {
    private func footprintPeak() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.ledger_phys_footprint_peak) : 0
    }

    func testEveryStoredArchiveStreamsToAFileInBoundedMemory() throws {
        guard ProcessInfo.processInfo.environment["CLAUDE_STATS_REAL_DATA"] == "1" else {
            throw XCTSkip("set CLAUDE_STATS_REAL_DATA=1")
        }
        let live = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ClaudeStatistics/data.db")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArchivedRealData-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clone = directory.appendingPathComponent("data.db")
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: live.path + suffix) {
            guard clonefile(live.path + suffix, clone.path + suffix, 0) == 0 else {
                throw XCTSkip("cannot clone the database (errno \(errno))")
            }
        }
        let database = DatabaseService(databasePath: clone.path)
        database.open()
        defer { database.close() }

        var archives: [(ProviderKind, String)] = []
        for provider in [ProviderKind.claude, .codex, .gemini] {
            archives += database.loadAllCached(provider: provider).filter { $0.value.hasTranscript }.keys.map { (provider, $0) }
        }

        let peakBefore = footprintPeak()
        var failed: [String] = []
        var total: Int64 = 0
        var largest: Int64 = 0
        var claudeFiles: [URL] = []
        let start = CFAbsoluteTimeGetCurrent()
        for (provider, sessionId) in archives {
            let url = directory.appendingPathComponent("\(provider.rawValue)-\(UUID().uuidString).jsonl")
            guard database.writeArchivedTranscript(provider: provider, sessionId: sessionId, to: url) else {
                failed.append("\(provider.rawValue):\(sessionId)")
                continue
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            total += size
            largest = max(largest, size)
            if provider == .claude, size < 20 << 20, claudeFiles.count < 5 {
                claudeFiles.append(url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let seconds = CFAbsoluteTimeGetCurrent() - start
        let peakGrowth = footprintPeak() - peakBefore

        // An archived Claude transcript pages like any transcript.
        for url in claudeFiles {
            let outline = try ClaudeProvider.shared.loadTranscriptOutline(at: url.path)
            XCTAssertEqual(outline.entries.count, ClaudeProvider.shared.parseMessages(at: url.path).count)
        }
        print("[archived-real] archives=\(archives.count) written=\(archives.count - failed.count) " +
              "failed=\(failed.count) bytes=\(total) largest=\(largest) " +
              "seconds=\(String(format: "%.1f", seconds)) peak_growth_mb=\(peakGrowth / 1_000_000) " +
              "claude_paged_checked=\(claudeFiles.count)")
        XCTAssertEqual(failed, [])
        XCTAssertLessThan(peakGrowth, 200_000_000, "streamed, not whole archives in memory")
    }
}
