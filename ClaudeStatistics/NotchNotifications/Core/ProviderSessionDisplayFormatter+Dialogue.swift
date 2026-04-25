import Foundation

/// Triptych dialogue ordering — collects the recent prompt / commentary /
/// tool-output / preview entries, sorts them chronologically (with stable
/// fallback by `order`), and dedupes adjacent entries that share text or a
/// semantic key. Used by the formatter when it needs a time-ordered view of
/// the latest exchange.
struct SessionDisplayEntry {
    let text: String
    let symbol: String
    let semanticKey: String?
    let timestamp: Date?
    let order: Int
}

extension ProviderSessionDisplayFormatter {
    var recentDialogueEntries: [SessionDisplayEntry] {
        var entries: [SessionDisplayEntry] = []

        if let note = cleanDisplayText(latestProgressNoteCandidate.text) {
            entries.append(SessionDisplayEntry(
                text: note,
                symbol: latestProgressNoteCandidate.symbol,
                semanticKey: nil,
                timestamp: session.latestProgressNoteAt,
                order: 0
            ))
        }

        if let toolOutput = cleanDisplayText(latestToolOutputCandidate.text) {
            entries.append(SessionDisplayEntry(
                text: toolOutput,
                symbol: latestToolOutputCandidate.symbol,
                semanticKey: session.latestToolOutputSummary?.semanticKey,
                timestamp: session.latestToolOutputAt,
                order: 1
            ))
        }

        if let prompt = cleanDisplayText(latestPromptCandidate.text) {
            entries.append(SessionDisplayEntry(
                text: prompt,
                symbol: latestPromptCandidate.symbol,
                semanticKey: nil,
                timestamp: session.latestPromptAt,
                order: 2
            ))
        }

        if let preview = cleanDisplayText(latestPreviewCandidate.text) {
            entries.append(SessionDisplayEntry(
                text: preview,
                symbol: latestPreviewCandidate.symbol,
                semanticKey: nil,
                timestamp: session.latestPreviewAt,
                order: 3
            ))
        }

        let sorted = entries.sorted(by: ProviderSessionDisplayFormatter.compareEntriesChronologically)
        var deduped: [SessionDisplayEntry] = []
        for entry in sorted {
            if let previous = deduped.last,
               Self.isDuplicateDisplayEntry(previous, entry) {
                continue
            }
            deduped.append(entry)
        }
        return deduped
    }

    static func comparableDisplayKey(_ text: String) -> String {
        text
            .replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func isDuplicateDisplayEntry(_ lhs: SessionDisplayEntry, _ rhs: SessionDisplayEntry) -> Bool {
        if let lhsKey = lhs.semanticKey, let rhsKey = rhs.semanticKey, lhsKey == rhsKey {
            return true
        }
        return comparableDisplayKey(lhs.text) == comparableDisplayKey(rhs.text)
    }

    static func compareEntriesChronologically(_ lhs: SessionDisplayEntry, _ rhs: SessionDisplayEntry) -> Bool {
        switch (lhs.timestamp, rhs.timestamp) {
        case let (l?, r?):
            if l != r { return l < r }
            return lhs.order < rhs.order
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.order < rhs.order
        }
    }

    static func compareEntriesReverseChronologically(_ lhs: SessionDisplayEntry, _ rhs: SessionDisplayEntry) -> Bool {
        switch (lhs.timestamp, rhs.timestamp) {
        case let (l?, r?):
            if l != r { return l > r }
            return lhs.order < rhs.order
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.order < rhs.order
        }
    }
}
