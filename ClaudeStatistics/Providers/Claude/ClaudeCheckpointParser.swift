import Foundation
import ClaudeStatisticsKit

/// Claude/Cowork share the same transcript format. State contains compact usage
/// contributions and metadata, not transcript bodies. Only changed message IDs
/// are reconciled against the other sources when a child or streaming turn moves.
enum ClaudeCheckpointParser {
    static var revision: String { "claude-checkpoint-1|\(TimeZone.current.identifier)" }

    struct Contribution: Codable {
        var model: String?
        var timestamp: Date?
        var tokens: ModelTokenStats

        func slice(fallbackModel: String) -> DaySlice {
            DaySlice(totalInputTokens: tokens.inputTokens, totalOutputTokens: tokens.outputTokens,
                     cacheCreation5mTokens: tokens.cacheCreation5mTokens,
                     cacheCreation1hTokens: tokens.cacheCreation1hTokens,
                     cacheCreationTotalTokens: tokens.cacheCreationTotalTokens,
                     cacheReadTokens: tokens.cacheReadTokens, messageCount: 1,
                     modelBreakdown: [model ?? fallbackModel: tokens])
        }
    }

    struct SourceState: Codable {
        var messages: [String: Contribution] = [:]
    }

    struct MainState: Codable {
        // These slices contain user/tool counts only; usage is reconciled across
        // source files separately, with main-message ownership taking priority.
        var stats = SessionStats()
        var quick = SessionQuickStats()
        var seenAssistants: Set<String> = []
        var seenTools: Set<String> = []
        var customTitle: String?
        var slug: String?
    }

    struct State: Codable {
        var sources: [String: SourceState] = [:]
        var main = MainState()
        var stats = SessionStats()
    }

    static func sourcePaths(for path: String) throws -> [String] {
        let file = URL(fileURLWithPath: path)
        let directory = file.deletingPathExtension().appendingPathComponent("subagents")
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            children = []
        }
        // FileManager may resolve /var → /private/var in returned URLs. Keep
        // child keys in the caller's root-path namespace so checkpoints and
        // watcher paths do not acquire different aliases for the same file.
        return [path] + children.filter { $0.pathExtension == "jsonl" }
            .map { directory.appendingPathComponent($0.lastPathComponent).path }.sorted()
    }

    static func parse(at path: String, checkpoint: SessionParseCheckpoint?) throws -> CheckpointedSessionUpdate? {
        try Task.checkCancellation()
        let paths = try sourcePaths(for: path)
        var snapshots: [String: TranscriptFileSnapshot] = [:]
        for source in paths { snapshots[source] = try TranscriptFileSnapshot.read(at: source) }
        var previous = checkpoint?.parserRevision == revision ? checkpoint : nil
        if let previous, Set(previous.sources.keys) == Set(paths),
           paths.allSatisfy({ previous.sources[$0]?.snapshot == snapshots[$0] }) { return nil }

        var state: State
        if let data = previous?.state, let decoded = try? decodeState(data) {
            state = decoded
        } else {
            state = State()
            previous = nil
        }
        let original = state
        var changedIDs: Set<String> = []
        var baseKeys: Set<Date> = []
        var sourceCheckpoints = previous?.sources ?? [:]
        var indexMessages: [IdentifiedSearchIndexMessage] = []
        var replacingIndex = previous == nil
        var bytesRead: Int64 = 0
        let timestamps = TranscriptTimestampParser()
        let calendar = Calendar.current

        for removed in Set(state.sources.keys).subtracting(paths) {
            if let old = state.sources.removeValue(forKey: removed) { changedIDs.formUnion(old.messages.keys) }
            sourceCheckpoints.removeValue(forKey: removed)
        }
        for sourcePath in paths {
            try Task.checkCancellation()
            let current = snapshots[sourcePath]!
            let prior = previous?.sources[sourcePath]
            if prior?.snapshot == current, state.sources[sourcePath] != nil { continue }
            let reader = try CheckpointedJSONLReader(path: sourcePath,
                                                     checkpoint: state.sources[sourcePath] == nil ? nil : prior)
            let appending = reader.isIncremental
            var source = appending ? state.sources[sourcePath]! : SourceState()
            if !appending {
                if let old = state.sources[sourcePath] { changedIDs.formUnion(old.messages.keys) }
                if sourcePath == path {
                    baseKeys.formUnion(state.main.stats.fiveMinSlices.keys)
                    state.main = MainState()
                    replacingIndex = true
                }
            }
            // The path may have changed between planning and opening the reader.
            guard reader.snapshot == current else { throw TranscriptFileReader.ReadError.changedDuringRead }
            while let record = try reader.readNext() {
                let entry = record.value
                let timestamp = timestamps.date(entry["timestamp"] as? String)
                let isMain = sourcePath == path
                let recordID = "offset:\(record.offset)"
                if isMain {
                    indexMessages.append(contentsOf: TranscriptParser.searchIndexProjection(
                        from: entry, recordID: recordID, timestamp: timestamp
                    ))
                    updateMain(entry, timestamp: timestamp, recordID: recordID, main: &state.main,
                               baseKeys: &baseKeys, calendar: calendar)
                }
                guard entry["type"] as? String == "assistant",
                      let message = entry["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                // Old child transcripts with no message ID cannot participate in
                // cross-file deduplication; match the existing full-parser rule.
                guard isMain || message["id"] is String else { continue }
                let id = message["id"] as? String ?? recordID
                let model = message["model"] as? String
                if !isMain && model == "<synthetic>" { continue }
                let creation = usage["cache_creation"] as? [String: Any] ?? [:]
                let tokens = ModelTokenStats(
                    inputTokens: usage["input_tokens"] as? Int ?? 0,
                    outputTokens: usage["output_tokens"] as? Int ?? 0,
                    cacheCreation5mTokens: creation["ephemeral_5m_input_tokens"] as? Int ?? 0,
                    cacheCreation1hTokens: creation["ephemeral_1h_input_tokens"] as? Int ?? 0,
                    cacheCreationTotalTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                    cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0, messageCount: 1
                )
                let resolvedModel = isMain ? ((model == "<synthetic>" ? nil : model) ?? state.main.stats.model) : model
                source.messages[id] = Contribution(model: resolvedModel, timestamp: timestamp, tokens: tokens)
                changedIDs.insert(id)
            }
            sourceCheckpoints[sourcePath] = try reader.finish()
            bytesRead += reader.bytesRead
            state.sources[sourcePath] = source
        }

        // Source addition/deletion/replacement invalidates the family, but a
        // later append is safe to leave for the next independent checkpoint.
        guard try sourcePaths(for: path) == paths else { throw TranscriptFileReader.ReadError.changedDuringRead }
        for sourcePath in paths {
            bytesRead += try sourceCheckpoints[sourcePath]!.validateAppendOnlySource(at: sourcePath)
        }
        if original.main.stats.model != state.main.stats.model {
            for source in original.sources.values {
                changedIDs.formUnion(source.messages.filter { $0.value.model == nil }.keys)
            }
            for source in state.sources.values {
                changedIDs.formUnion(source.messages.filter { $0.value.model == nil }.keys)
            }
        }
        var slices = original.stats.fiveMinSlices
        for key in baseKeys {
            var value = slices[key, default: DaySlice()]
            value.subtract(original.main.stats.fiveMinSlices[key, default: DaySlice()])
            value.merge(state.main.stats.fiveMinSlices[key, default: DaySlice()])
            slices[key] = value.isEmpty ? nil : value
        }
        let oldChildren = original.sources.keys.filter { $0 != path }.sorted().reversed()
        let newChildren = paths.dropFirst().reversed()
        for id in changedIDs {
            try Task.checkCancellation()
            let old = original.sources[path]?.messages[id] ?? oldChildren.lazy.compactMap { original.sources[$0]?.messages[id] }.first
            let new = state.sources[path]?.messages[id] ?? newChildren.lazy.compactMap { state.sources[$0]?.messages[id] }.first
            apply(old, fallbackModel: original.main.stats.model, subtract: true, slices: &slices, calendar: calendar)
            apply(new, fallbackModel: state.main.stats.model, subtract: false, slices: &slices, calendar: calendar)
        }
        state.stats = state.main.stats
        state.stats.fiveMinSlices = slices
        state.stats.precomputeAggregates()
        var quick = state.main.quick
        quick.model = state.stats.model == "Unknown" ? nil : state.stats.model
        quick.startTime = state.stats.startTime ?? quick.startTime
        quick.messageCount = state.stats.messageCount
        quick.userMessageCount = state.stats.userMessageCount
        quick.totalTokens = state.stats.totalTokens
        quick.estimatedCost = state.stats.estimatedCost
        quick.lastPrompt = state.stats.lastPrompt
        quick.lastPromptAt = state.stats.lastPromptAt
        quick.lastOutputPreview = state.stats.lastOutputPreview
        quick.lastOutputPreviewAt = state.stats.lastOutputPreviewAt
        quick.latestProgressNote = state.stats.lastOutputPreview
        quick.latestProgressNoteAt = state.stats.lastOutputPreviewAt
        quick.sessionName = TitleSanitizer.sanitize(state.main.customTitle ?? state.main.slug)
        return .init(stats: state.stats, quickStats: quick,
                     searchIndex: replacingIndex ? .replaceIdentified(indexMessages) : .update(upserting: indexMessages, removing: []),
                     checkpoint: .init(parserRevision: revision, sources: sourceCheckpoints, state: try encodeState(state)),
                     bytesRead: bytesRead)
    }

    // MARK: - State encoding

    // The per-message ledger and the seen-ID sets grow with the session and are
    // decoded and re-encoded on every append, so they use a compact binary
    // layout — on a 24k-message session about ten times faster than JSON
    // Codable. The small remainder stays JSON. States written as whole JSON by
    // earlier builds still decode, so upgrading does not reparse any history.
    private static let stateMagic = Array("CCP2".utf8)

    private struct StateHeader: Codable {
        var mainStats: SessionStats
        var quick: SessionQuickStats
        var customTitle: String?
        var slug: String?
        var stats: SessionStats
    }

    private enum StateDecodingError: Error { case malformed }

    private struct StateWriter {
        var bytes: [UInt8] = []
        mutating func count(_ value: Int) { append(UInt32(value).littleEndian) }
        mutating func integer(_ value: Int64) { append(value.littleEndian) }
        mutating func string(_ value: String) {
            var value = value
            value.withUTF8 { utf8 in
                count(utf8.count)
                bytes.append(contentsOf: utf8)
            }
        }
        private mutating func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
        }
    }

    private struct StateReader {
        let raw: UnsafeRawBufferPointer
        var position: Int
        mutating func take(_ length: Int) throws -> UnsafeRawBufferPointer {
            guard length >= 0, length <= raw.count - position else { throw StateDecodingError.malformed }
            defer { position += length }
            return UnsafeRawBufferPointer(rebasing: raw[position..<position + length])
        }
        mutating func count() throws -> Int { Int(UInt32(littleEndian: try take(4).loadUnaligned(as: UInt32.self))) }
        mutating func integer() throws -> Int64 { Int64(littleEndian: try take(8).loadUnaligned(as: Int64.self)) }
        mutating func string() throws -> String { String(decoding: try take(try count()), as: UTF8.self) }
    }

    static func encodeState(_ state: State) throws -> Data {
        var out = StateWriter()
        out.bytes.reserveCapacity(state.sources.values.reduce(0) { $0 + $1.messages.count } * 110 + 64 * 1024)
        out.bytes.append(contentsOf: stateMagic)
        let header = try JSONEncoder().encode(StateHeader(mainStats: state.main.stats, quick: state.main.quick,
                                                          customTitle: state.main.customTitle, slug: state.main.slug,
                                                          stats: state.stats))
        out.count(header.count)
        out.bytes.append(contentsOf: header)
        out.count(state.sources.count)
        for (path, source) in state.sources {
            out.string(path)
            out.count(source.messages.count)
            for (id, contribution) in source.messages {
                out.string(id)
                let flags: UInt8 = (contribution.model == nil ? 0 : 1) | (contribution.timestamp == nil ? 0 : 2)
                out.bytes.append(flags)
                if let model = contribution.model { out.string(model) }
                if let timestamp = contribution.timestamp {
                    out.integer(Int64(bitPattern: timestamp.timeIntervalSinceReferenceDate.bitPattern))
                }
                let tokens = contribution.tokens
                out.integer(Int64(tokens.inputTokens))
                out.integer(Int64(tokens.outputTokens))
                out.integer(Int64(tokens.cacheCreation5mTokens))
                out.integer(Int64(tokens.cacheCreation1hTokens))
                out.integer(Int64(tokens.cacheCreationTotalTokens))
                out.integer(Int64(tokens.cacheReadTokens))
                out.integer(Int64(tokens.messageCount))
            }
        }
        for ids in [state.main.seenAssistants, state.main.seenTools] {
            out.count(ids.count)
            for id in ids { out.string(id) }
        }
        return Data(out.bytes)
    }

    static func decodeState(_ data: Data) throws -> State {
        guard data.starts(with: stateMagic) else { return try JSONDecoder().decode(State.self, from: data) }
        return try data.withUnsafeBytes { raw in
            var input = StateReader(raw: raw, position: stateMagic.count)
            let header = try JSONDecoder().decode(StateHeader.self, from: Data(try input.take(try input.count())))
            var state = State()
            state.main.stats = header.mainStats
            state.main.quick = header.quick
            state.main.customTitle = header.customTitle
            state.main.slug = header.slug
            state.stats = header.stats
            let sourceCount = try input.count()
            for _ in 0..<sourceCount {
                let path = try input.string()
                let messageCount = try input.count()
                var source = SourceState()
                source.messages.reserveCapacity(messageCount)
                for _ in 0..<messageCount {
                    let id = try input.string()
                    let flags = try input.take(1)[0]
                    let model = try flags & 1 != 0 ? input.string() : nil
                    let timestamp = try flags & 2 != 0
                        ? Date(timeIntervalSinceReferenceDate: Double(bitPattern: UInt64(bitPattern: input.integer())))
                        : nil
                    let tokens = ModelTokenStats(
                        inputTokens: Int(try input.integer()), outputTokens: Int(try input.integer()),
                        cacheCreation5mTokens: Int(try input.integer()), cacheCreation1hTokens: Int(try input.integer()),
                        cacheCreationTotalTokens: Int(try input.integer()), cacheReadTokens: Int(try input.integer()),
                        messageCount: Int(try input.integer())
                    )
                    source.messages[id] = Contribution(model: model, timestamp: timestamp, tokens: tokens)
                }
                state.sources[path] = source
            }
            let assistantCount = try input.count()
            state.main.seenAssistants.reserveCapacity(assistantCount)
            for _ in 0..<assistantCount { state.main.seenAssistants.insert(try input.string()) }
            let toolCount = try input.count()
            state.main.seenTools.reserveCapacity(toolCount)
            for _ in 0..<toolCount { state.main.seenTools.insert(try input.string()) }
            guard input.position == raw.count else { throw StateDecodingError.malformed }
            return state
        }
    }

    private static func apply(_ contribution: Contribution?, fallbackModel: String, subtract: Bool,
                              slices: inout [Date: DaySlice], calendar: Calendar) {
        guard let contribution, let timestamp = contribution.timestamp else { return }
        let key = fiveMinKey(timestamp, calendar: calendar)
        var value = slices[key, default: DaySlice()]
        let delta = contribution.slice(fallbackModel: fallbackModel)
        if subtract { value.subtract(delta) } else { value.merge(delta) }
        slices[key] = value.isEmpty ? nil : value
    }

    private static func fiveMinKey(_ date: Date, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        parts.minute = ((parts.minute ?? 0) / 5) * 5
        parts.second = 0
        parts.nanosecond = 0
        let key = calendar.date(from: parts) ?? date
        // Preserve the historical midnight attribution used by Claude totals.
        return parts.hour == 0 ? calendar.date(byAdding: .hour, value: -1, to: key) ?? key : key
    }

    private static func updateMain(_ entry: [String: Any], timestamp: Date?, recordID: String,
                                   main: inout MainState, baseKeys: inout Set<Date>, calendar: Calendar) {
        if let title = entry["customTitle"] as? String { main.customTitle = title }
        if let slug = entry["slug"] as? String { main.slug = slug }
        if main.quick.startTime == nil { main.quick.startTime = timestamp }
        let type = entry["type"] as? String ?? ""
        guard type == "user" || type == "human" || type == "assistant" else { return }
        if let timestamp {
            main.stats.startTime = min(main.stats.startTime ?? timestamp, timestamp)
            main.stats.endTime = max(main.stats.endTime ?? timestamp, timestamp)
        }
        let message = entry["message"] as? [String: Any] ?? [:]
        if type != "assistant" {
            main.stats.userMessageCount += 1
            if let timestamp {
                let key = fiveMinKey(timestamp, calendar: calendar)
                main.stats.fiveMinSlices[key, default: DaySlice()].messageCount += 1
                baseKeys.insert(key)
            }
            if let text = TranscriptParser.rawMessageText(message), let cleaned = TranscriptParser.cleanUserDisplayText(text) {
                if main.quick.topic == nil { main.quick.topic = TranscriptParser.cleanTopic(cleaned) }
                main.stats.lastPrompt = cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
                main.stats.lastPromptAt = timestamp
            }
            return
        }
        guard entry["message"] is [String: Any] else { return }
        if main.seenAssistants.insert(message["id"] as? String ?? recordID).inserted {
            main.stats.assistantMessageCount += 1
        }
        if let model = message["model"] as? String, model != "Unknown", model != "<synthetic>" { main.stats.model = model }
        if let preview = TranscriptParser.extractAssistantPreview(fromRawMessage: message) {
            main.stats.lastOutputPreview = preview
            main.stats.lastOutputPreviewAt = timestamp
        }
        guard let usage = message["usage"] as? [String: Any] else { return }
        let context = (usage["input_tokens"] as? Int ?? 0) + (usage["cache_creation_input_tokens"] as? Int ?? 0) + (usage["cache_read_input_tokens"] as? Int ?? 0)
        if context > 0 { main.stats.contextTokens = context }
        for (index, item) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
            guard item["type"] as? String == "tool_use", let name = item["name"] as? String else { continue }
            let id = item["id"] as? String ?? "\(recordID):\(index)"
            guard main.seenTools.insert(id).inserted, let timestamp else { continue }
            let key = fiveMinKey(timestamp, calendar: calendar)
            main.stats.fiveMinSlices[key, default: DaySlice()].toolUseCounts[name, default: 0] += 1
            main.stats.fiveMinSlices[key, default: DaySlice()].messageCount += 1
            baseKeys.insert(key)
        }
    }
}
