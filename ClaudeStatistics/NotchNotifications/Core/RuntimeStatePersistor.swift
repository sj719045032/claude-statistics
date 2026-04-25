import Foundation

/// Owns the on-disk JSON snapshot of `runtimeByKey`. Two responsibilities:
/// 1. Debounced background writes — hook events fire 5–10× per Claude turn
///    and each one used to trigger a synchronous JSONEncoder + atomic file
///    write on the MainActor, which made click/scroll interactions stutter.
///    Coalesce into one write every 400ms on a utility queue.
/// 2. Launch-time load + normalization — older payloads may carry duplicate
///    keys (e.g. Claude `parent::child` session IDs) that need canonicalising
///    and de-duplicating before being merged back into runtime state.
@MainActor
final class RuntimeStatePersistor {
    let fileURL: URL
    private var pendingTask: DispatchWorkItem?
    private static let writeQueue = DispatchQueue(
        label: "com.claude-statistics.runtime-persist",
        qos: .utility
    )
    private static let debounceInterval: TimeInterval = 0.4

    static let defaultFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Claude Statistics", isDirectory: true)
            .appendingPathComponent("active-sessions-runtime.json")
    }()

    init(fileURL: URL = RuntimeStatePersistor.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Launch-time read. Returns nil when there's no file or the JSON can't
    /// be decoded — caller treats that as an empty starting state.
    func load() -> [String: RuntimeSession]? {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: RuntimeSession].self, from: data) else {
            return nil
        }
        return Self.normalize(decoded)
    }

    /// Debounced write. Replaces any pending task so only the latest snapshot
    /// reaches disk. Snapshot is captured by value at call time, so MainActor
    /// state can mutate freely afterwards.
    func scheduleWrite(_ runtime: [String: RuntimeSession]) {
        pendingTask?.cancel()
        let url = fileURL
        let task = DispatchWorkItem {
            Self.write(runtime, to: url)
        }
        pendingTask = task
        Self.writeQueue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: task)
    }

    /// Synchronous write used at app shutdown. Cancels any pending debounced
    /// task so we don't write the snapshot twice.
    func flushWrite(_ runtime: [String: RuntimeSession]) {
        pendingTask?.cancel()
        pendingTask = nil
        Self.write(runtime, to: fileURL)
    }

    // MARK: - Private

    private static func write(_ runtime: [String: RuntimeSession], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(runtime)
            try data.write(to: url, options: .atomic)
        } catch {
            DiagnosticLogger.shared.warning("Failed to persist active session runtime: \(error.localizedDescription)")
        }
    }

    private static func normalize(
        _ runtime: [String: RuntimeSession]
    ) -> [String: RuntimeSession] {
        var normalized: [String: RuntimeSession] = [:]

        for entry in runtime.values {
            var value = entry
            value.sessionId = canonicalSessionID(provider: value.provider, sessionId: value.sessionId)
            let key = key(provider: value.provider, sessionId: value.sessionId)

            if let existing = normalized[key] {
                normalized[key] = preferred(existing: existing, candidate: value)
            } else {
                normalized[key] = value
            }
        }

        return normalized
    }

    private static func preferred(
        existing: RuntimeSession,
        candidate: RuntimeSession
    ) -> RuntimeSession {
        if candidate.lastActivityAt != existing.lastActivityAt {
            return candidate.lastActivityAt > existing.lastActivityAt ? candidate : existing
        }

        let existingSignals = focusSignalCount(for: existing)
        let candidateSignals = focusSignalCount(for: candidate)
        if candidateSignals != existingSignals {
            return candidateSignals > existingSignals ? candidate : existing
        }

        let existingPayloadSignals = payloadSignalCount(for: existing)
        let candidatePayloadSignals = payloadSignalCount(for: candidate)
        if candidatePayloadSignals != existingPayloadSignals {
            return candidatePayloadSignals > existingPayloadSignals ? candidate : existing
        }

        return existing
    }

    private static func focusSignalCount(for runtime: RuntimeSession) -> Int {
        var count = 0
        if runtime.pid != nil { count += 1 }
        if runtime.tty?.nilIfEmpty != nil { count += 1 }
        if runtime.terminalSocket?.nilIfEmpty != nil { count += 1 }
        if runtime.terminalWindowID?.nilIfEmpty != nil { count += 1 }
        if runtime.terminalTabID?.nilIfEmpty != nil { count += 1 }
        if runtime.terminalStableID?.nilIfEmpty != nil { count += 1 }
        return count
    }

    private static func payloadSignalCount(for runtime: RuntimeSession) -> Int {
        var count = 0
        if runtime.currentActivity?.nilIfEmpty != nil { count += 1 }
        if runtime.latestProgressNote?.nilIfEmpty != nil { count += 1 }
        if runtime.latestPrompt?.nilIfEmpty != nil { count += 1 }
        if runtime.latestPreview?.nilIfEmpty != nil { count += 1 }
        if runtime.latestToolOutput?.nilIfEmpty != nil { count += 1 }
        if runtime.currentToolName?.nilIfEmpty != nil { count += 1 }
        if runtime.currentToolDetail?.nilIfEmpty != nil { count += 1 }
        return count
    }

    private static func key(provider: ProviderKind, sessionId: String) -> String {
        "\(provider.rawValue):\(sessionId)"
    }

    private static func canonicalSessionID(provider: ProviderKind, sessionId: String) -> String {
        guard provider == .claude else { return sessionId }
        return canonicalClaudeSessionID(sessionId)
    }

    private static func canonicalClaudeSessionID(_ sessionId: String) -> String {
        guard sessionId.contains("::"),
              let rawID = sessionId.components(separatedBy: "::").last?.nilIfEmpty else {
            return sessionId
        }
        return rawID
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
