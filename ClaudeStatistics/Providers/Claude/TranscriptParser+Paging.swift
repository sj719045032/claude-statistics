import Foundation
import ClaudeStatisticsKit

/// Bounded transcript detail for Claude/Cowork. The outline pass streams the
/// file once and keeps only per-row identity plus the bytes each row was built
/// from; materialization re-reads just those bytes. Both passes share
/// `recordRows` and `RowLinker` with the whole-file parse, so a page is
/// byte-for-byte the row the whole-file parse would have produced.
extension TranscriptParser {

    func loadTranscriptOutline(at path: String) throws -> TranscriptOutline {
        let signpostState = PerformanceTracer.begin("Claude.transcriptOutline")
        defer { PerformanceTracer.end("Claude.transcriptOutline", signpostState) }

        let sessionId = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let reader = try TranscriptFileReader(path: path, includeFinalLine: true)
        let decoder = JSONDecoder()

        var linker = RowLinker()
        var entries: [TranscriptOutlineEntry] = []
        /// Last result record per tool id — the whole-file parse also lets the
        /// last result win.
        var resultRanges: [String: TranscriptByteRange] = [:]

        while let record = try reader.readNext() {
            let end = reader.nextOffset
            let start = end - Int64(record.count) - (reader.lastRecordWasTerminated ? 1 : 0)
            let range = TranscriptByteRange(offset: start, length: Int64(record.count))
            // Row extraction bridges to Foundation and autoreleases; without a
            // pool per record the outline pass holds the whole transcript's
            // bridged strings, which is the cost it exists to avoid.
            autoreleasepool {
                guard !record.isEmpty,
                      let entry = try? decoder.decode(TranscriptEntry.self, from: record) else { return }

                for row in TranscriptParser.recordRows(from: entry, recordOffset: start, sessionId: sessionId) {
                    if case .toolResult(let toolId, _) = row {
                        resultRanges[toolId] = range
                        continue
                    }
                    guard let message = row.message else { continue }
                    let locator = TranscriptRecordLocator(source: path, ranges: [range])
                    switch linker.accept(row) {
                    case .appended(let slot):
                        entries.append(TranscriptOutlineEntry(
                            id: slot.id, role: slot.role, toolName: slot.toolName,
                            timestamp: message.timestamp, locator: locator
                        ))
                    case .revised(let index):
                        let old = entries[index]
                        entries[index] = TranscriptOutlineEntry(
                            id: old.id, role: old.role, toolName: old.toolName,
                            timestamp: message.timestamp, locator: locator
                        )
                    case .skipped:
                        continue
                    }
                }
            }
        }

        for (toolId, resultRange) in resultRanges {
            guard let index = linker.resultTarget(for: toolId), index < entries.count else { continue }
            let old = entries[index]
            entries[index] = TranscriptOutlineEntry(
                id: old.id, role: old.role, toolName: old.toolName, timestamp: old.timestamp,
                locator: TranscriptRecordLocator(
                    source: old.locator.source, ranges: old.locator.ranges + [resultRange]
                )
            )
        }

        return TranscriptOutline(entries: entries,
                                 sources: [path: try .coveringWholeFile(reader.snapshot, at: path)])
    }

    func loadTranscriptPage(at path: String,
                            entries: [TranscriptOutlineEntry]) throws -> [TranscriptDisplayMessage] {
        guard !entries.isEmpty else { return [] }
        let sessionId = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let decoder = JSONDecoder()
        var readers: [String: TranscriptRecordReader] = [:]
        defer { for reader in readers.values { reader.close() } }

        var messages: [TranscriptDisplayMessage] = []
        messages.reserveCapacity(entries.count)

        for entry in entries {
            try Task.checkCancellation()
            let source = entry.locator.source
            let reader: TranscriptRecordReader
            if let existing = readers[source] {
                reader = existing
            } else {
                reader = try TranscriptRecordReader(path: source)
                readers[source] = reader
            }

            guard let callRange = entry.locator.ranges.first,
                  let data = try reader.read(callRange),
                  let record = try? decoder.decode(TranscriptEntry.self, from: data) else { continue }
            let rows = TranscriptParser.recordRows(from: record, recordOffset: callRange.offset,
                                                   sessionId: sessionId)
            guard let row = Self.row(matching: entry, in: rows) else { continue }
            var message = TranscriptParser.withId(entry.id, row)

            if entry.role == "tool", entry.locator.ranges.count > 1,
               let resultRange = entry.locator.ranges.last,
               let data = try reader.read(resultRange),
               let record = try? decoder.decode(TranscriptEntry.self, from: data) {
                let toolId = String(entry.id.dropFirst("tool-".count))
                for row in TranscriptParser.recordRows(from: record, recordOffset: resultRange.offset,
                                                       sessionId: sessionId) {
                    guard case .toolResult(let id, let text) = row, id == toolId else { continue }
                    message = TranscriptDisplayMessage(
                        id: message.id, role: message.role, text: message.text,
                        timestamp: message.timestamp, toolName: message.toolName, toolDetail: text
                    )
                }
            }
            messages.append(message)
        }
        return messages
    }

    /// Pick the row a record contributed for this outline entry. Ids are stable
    /// for assistant text and tool rows; a user record contributes exactly one
    /// row, whose id the linker assigned from the running counter.
    private static func row(matching entry: TranscriptOutlineEntry,
                            in rows: [RecordRow]) -> TranscriptDisplayMessage? {
        for row in rows {
            switch row {
            case .user(let message) where entry.role == "user":
                return message
            case .assistantText(let message) where message.id == entry.id:
                return message
            case .toolUse(_, let message) where message.id == entry.id:
                return message
            default:
                continue
            }
        }
        return nil
    }
}
