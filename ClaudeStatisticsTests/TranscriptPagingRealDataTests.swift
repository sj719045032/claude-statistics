import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Read-only comparison of the paged transcript path against the whole-file
/// parse on this machine's real Claude transcripts. Skipped unless
/// `CLAUDE_STATS_REAL_DATA=1`, so the suite stays hermetic; run it when
/// changing the parser or the outline/page contract:
///
///     TEST_RUNNER_CLAUDE_STATS_REAL_DATA=1 bash scripts/run-tests.sh
///
/// (`xcodebuild test` only forwards variables to the test host when they carry
/// the `TEST_RUNNER_` prefix.)
///
/// `CLAUDE_STATS_REAL_DATA_FILES` caps how many transcripts are compared
/// (default 12, largest first).
final class TranscriptPagingRealDataTests: XCTestCase {
    private func realTranscripts() throws -> [URL] {
        let root = URL(fileURLWithPath: (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/projects"))
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return []
        }
        var files: [(URL, Int)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else { continue }
            files.append((url, size))
        }
        let limit = Int(ProcessInfo.processInfo.environment["CLAUDE_STATS_REAL_DATA_FILES"] ?? "12") ?? 12
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    func testRealTranscriptsMatchTheWholeFileParse() throws {
        guard ProcessInfo.processInfo.environment["CLAUDE_STATS_REAL_DATA"] == "1" else {
            throw XCTSkip("set CLAUDE_STATS_REAL_DATA=1 to compare against real transcripts")
        }
        let files = try realTranscripts()
        try XCTSkipIf(files.isEmpty, "no local Claude transcripts")

        let parser = TranscriptParser.shared
        for file in files {
            let size = try TranscriptFileSnapshot.read(at: file.path).size

            let wholeStart = CFAbsoluteTimeGetCurrent()
            let whole = parser.parseMessages(at: file.path)
            let wholeSeconds = CFAbsoluteTimeGetCurrent() - wholeStart

            let outlineStart = CFAbsoluteTimeGetCurrent()
            let outline = try parser.loadTranscriptOutline(at: file.path)
            let outlineSeconds = CFAbsoluteTimeGetCurrent() - outlineStart

            XCTAssertEqual(outline.entries.map(\.id), whole.map(\.id), file.lastPathComponent)
            XCTAssertEqual(outline.entries.map(\.role), whole.map(\.role), file.lastPathComponent)
            XCTAssertEqual(outline.entries.map(\.toolName), whole.map(\.toolName), file.lastPathComponent)

            // Every row, one page at a time, must reproduce the whole parse.
            let pageSize = TranscriptPagingModel.defaultPageSize
            var pagedSeconds = 0.0
            var pageBytes: Int64 = 0
            var rebuilt: [TranscriptDisplayMessage] = []
            for start in stride(from: 0, to: outline.entries.count, by: pageSize) {
                let slice = Array(outline.entries[start..<min(start + pageSize, outline.entries.count)])
                pageBytes += slice.reduce(0) { $0 + $1.locator.byteCount }
                let pageStart = CFAbsoluteTimeGetCurrent()
                rebuilt += try parser.loadTranscriptPage(at: file.path, entries: slice)
                pagedSeconds += CFAbsoluteTimeGetCurrent() - pageStart
            }

            XCTAssertEqual(rebuilt.count, whole.count, file.lastPathComponent)
            for (left, right) in zip(rebuilt, whole) {
                XCTAssertEqual(left.id, right.id, file.lastPathComponent)
                XCTAssertEqual(left.text, right.text, "\(file.lastPathComponent) row \(left.id)")
                XCTAssertEqual(left.toolName, right.toolName, "\(file.lastPathComponent) row \(left.id)")
                XCTAssertEqual(left.toolDetail, right.toolDetail, "\(file.lastPathComponent) row \(left.id)")
                XCTAssertEqual(left.timestamp, right.timestamp, "\(file.lastPathComponent) row \(left.id)")
            }

            // What one screenful actually costs, versus the whole transcript.
            let firstPage = Array(outline.entries.prefix(pageSize))
            let firstPageBytes = firstPage.reduce(Int64(0)) { $0 + $1.locator.byteCount }
            let lastPage = Array(outline.entries.suffix(pageSize))
            let lastPageBytes = lastPage.reduce(Int64(0)) { $0 + $1.locator.byteCount }

            // Everything a parse still holds when it returns, autoreleased
            // objects included. A per-record `JSONSerialization` loop with no
            // pool keeps the whole file alive here.
            var sessionLive = 0
            var messagesLive = 0
            var outlineLive = 0
            autoreleasepool {
                sessionLive = AllocationProbe.liveAtReturn { _ = parser.parseSession(at: file.path) }
            }
            autoreleasepool {
                messagesLive = AllocationProbe.liveAtReturn { _ = parser.parseMessages(at: file.path) }
            }
            autoreleasepool {
                outlineLive = AllocationProbe.liveAtReturn { _ = try? parser.loadTranscriptOutline(at: file.path) }
            }

            // What one keystroke used to cost on the main thread: build the
            // joined search text for every row and test it. The paged view
            // runs this off the main actor, in batches, debounced.
            let searchStart = CFAbsoluteTimeGetCurrent()
            var hits = 0
            for message in whole {
                let text = SearchUtils.transcriptSearchableText(for: message)
                if SearchUtils.textMatches(query: "error", in: text) { hits += 1 }
            }
            let searchSeconds = CFAbsoluteTimeGetCurrent() - searchStart

            // Retained cost of the two shapes: every row body plus the search
            // text cache the view used to build, versus the outline alone.
            let wholeBytes = whole.reduce(0) {
                $0 + $1.text.utf8.count + ($1.toolDetail?.utf8.count ?? 0)
                    + ($1.editOldString?.utf8.count ?? 0) + ($1.editNewString?.utf8.count ?? 0)
            }
            let outlineBytes = outline.entries.reduce(0) {
                $0 + $1.id.utf8.count + $1.role.utf8.count + ($1.toolName?.utf8.count ?? 0)
                    + $1.locator.ranges.count * 16 + 64
            }

            print("""
            [paging] \(file.lastPathComponent) size=\(size) rows=\(whole.count) \
            whole=\(String(format: "%.3f", wholeSeconds))s \
            outline=\(String(format: "%.3f", outlineSeconds))s \
            allPages=\(String(format: "%.3f", pagedSeconds))s \
            citedBytes=\(pageBytes) firstPageBytes=\(firstPageBytes) lastPageBytes=\(lastPageBytes) \
            wholeRetained=\(wholeBytes) outlineRetained=\(outlineBytes) \
            fullScanSearch=\(String(format: "%.3f", searchSeconds))s hits=\(hits) \
            liveAtReturn session=\(sessionLive) messages=\(messagesLive) outline=\(outlineLive)
            """)

            XCTAssertLessThan(outlineBytes, wholeBytes,
                              "\(file.lastPathComponent): the outline must be cheaper to retain")

            XCTAssertLessThanOrEqual(pageBytes, size,
                                     "\(file.lastPathComponent): pages must not cite more than the file")

            // A parse must not still be holding the transcript when it returns.
            // Decoding and row extraction bridge to Foundation, which
            // autoreleases; before pools were added per record this transcript
            // measured 130,516,688 bytes live after `parseSession` and
            // 293,818,432 after `parseMessages` and after the outline pass.
            // Synthetic fixtures did not reproduce it — only real transcripts
            // did — so this assertion lives here, not in the hermetic suite.
            // `parseMessages` legitimately keeps the rows it returns.
            XCTAssertLessThan(sessionLive, 8 * 1024 * 1024,
                              "\(file.lastPathComponent): parseSession held \(sessionLive) bytes")
            XCTAssertLessThan(outlineLive, 8 * 1024 * 1024,
                              "\(file.lastPathComponent): the outline pass held \(outlineLive) bytes")
            XCTAssertLessThan(messagesLive, max(8 * 1024 * 1024, wholeBytes * 2),
                              "\(file.lastPathComponent): parseMessages held \(messagesLive) bytes")
        }
    }
}
