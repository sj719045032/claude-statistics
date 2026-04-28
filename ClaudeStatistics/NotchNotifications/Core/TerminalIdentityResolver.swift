import Foundation
import ClaudeStatisticsKit

/// Pure rules around mapping `RuntimeSession` records to terminal tabs.
/// Three families of logic that all hinge on Ghostty's quirks (a single
/// stable surface ID can briefly appear under two TTYs across split tabs;
/// closed tabs leave stale persisted records claiming the new tab's IDs):
///
/// 1. Per-record sanitization — drop generic "waiting for input" previews,
///    expire stale approvals so the notch doesn't show a grey "Allow?"
///    button for a session the user already moved on from.
/// 2. Cross-record sanitization — when two sessions claim the same Ghostty
///    `stableID` via different TTYs, strip the contested IDs from all but
///    the most recently active so focus targeting can't bind to the wrong
///    surface.
/// 3. Tab-level displacement — when a brand new SessionStart fires, find
///    the prior sessions sitting on the same TTY/tab/stableID so the
///    tracker can evict them. Returned as a list of (key, sessionId) so
///    the tracker can update both `runtimeByKey` and `displacedSessionIds`.
enum TerminalIdentityResolver {
    private static let ghosttyBundleID = "com.mitchellh.ghostty"

    // MARK: - Per-record

    static func sanitized(_ runtime: RuntimeSession) -> RuntimeSession {
        var copy = runtime
        if let preview = copy.latestPreview, isGenericWaitingPreview(preview) {
            copy.latestPreview = nil
        }
        if let approvalStartedAt = copy.approvalStartedAt,
           Date().timeIntervalSince(approvalStartedAt) >= ActiveSession.approvalStaleInterval {
            copy.approvalToolName = nil
            copy.approvalToolDetail = nil
            copy.approvalStartedAt = nil
            copy.approvalToolUseId = nil
        }
        return copy
    }

    // MARK: - Cross-record (Ghostty collisions)

    /// When several Ghostty runtime records share a `terminalStableID` but
    /// live on distinct TTYs, the stable ID is ambiguous — clear it (and
    /// the window/tab IDs) on every entry except the most-recently-active
    /// one so focus targeting falls back to TTY-only.
    static func sanitizedGhosttyCollisions(
        _ runtimes: [String: RuntimeSession]
    ) -> [String: RuntimeSession] {
        var result = runtimes
        let ghosttyEntries = runtimes.compactMap { key, runtime -> (key: String, runtime: RuntimeSession)? in
            guard TerminalRegistry.bundleId(forTerminalName: runtime.terminalName) == ghosttyBundleID,
                  runtime.terminalStableID?.nilIfEmpty != nil,
                  runtime.tty?.nilIfEmpty != nil else {
                return nil
            }
            return (key, runtime)
        }

        let grouped = Dictionary(grouping: ghosttyEntries) { $0.runtime.terminalStableID ?? "" }
        for (stableID, entries) in grouped where entries.count > 1 {
            let distinctTTYs = Set(entries.compactMap { $0.runtime.tty?.nilIfEmpty })
            guard distinctTTYs.count > 1 else { continue }

            let keepKey = entries
                .max { $0.runtime.lastActivityAt < $1.runtime.lastActivityAt }?
                .key
            for entry in entries where entry.key != keepKey {
                guard var runtime = result[entry.key] else { continue }
                runtime.terminalWindowID = nil
                runtime.terminalTabID = nil
                runtime.terminalStableID = nil
                result[entry.key] = runtime
                DiagnosticLogger.shared.warning(
                    "Cleared ambiguous Ghostty terminal id key=\(entry.key) stableID=\(stableID) tty=\(entry.runtime.tty ?? "-")"
                )
            }
        }

        return result
    }

    // MARK: - Tab-level displacement

    struct DisplacedSession {
        let key: String
        let sessionId: String
    }

    /// Find prior runtime entries that should be evicted because a brand
    /// new session just started on the same TTY / tab / stableID. Pure
    /// query — caller mutates `runtimeByKey` and `displacedSessionIds`.
    static func sessionsDisplaced(
        by event: AttentionEvent,
        excludingKey newKey: String,
        in runtimes: [String: RuntimeSession]
    ) -> [DisplacedSession] {
        let tty = event.tty?.nilIfEmpty
        let tabID = event.terminalTabID?.nilIfEmpty
        let stableID = event.terminalStableID?.nilIfEmpty
        let isGhostty = TerminalRegistry.bundleId(forTerminalName: event.terminalName) == ghosttyBundleID
        // Need at least one terminal identity to match on, otherwise we'd
        // evict unrelated sessions across different tabs.
        guard tty != nil || tabID != nil || stableID != nil else { return [] }

        return runtimes.compactMap { key, runtime -> DisplacedSession? in
            guard key != newKey else { return nil }
            if let tty, runtime.tty == tty {
                return DisplacedSession(key: key, sessionId: runtime.sessionId)
            }
            if let stableID, runtime.terminalStableID == stableID {
                if isGhostty, let eventTTY = tty, let runtimeTTY = runtime.tty, runtimeTTY != eventTTY {
                    return nil
                }
                return DisplacedSession(key: key, sessionId: runtime.sessionId)
            }
            if !isGhostty, let tabID, runtime.terminalTabID == tabID {
                return DisplacedSession(key: key, sessionId: runtime.sessionId)
            }
            return nil
        }
    }

    /// Decide whether an incoming event's terminal identity should be
    /// trusted for `key`, given everything else currently in `runtimes`.
    /// Only Ghostty surfaces this problem — other terminals' IDs are
    /// trustworthy. When two Ghostty surfaces briefly claim the same
    /// stableID/tabID via different TTYs, reject the new claim and log
    /// once so the operator can investigate.
    static func acceptsTerminalIdentity(
        forKey key: String,
        terminalName: String?,
        incomingTTY: String?,
        incomingTabID: String?,
        incomingStableID: String?,
        in runtimes: [String: RuntimeSession]
    ) -> Bool {
        guard TerminalRegistry.bundleId(forTerminalName: terminalName) == ghosttyBundleID else {
            return true
        }
        guard incomingStableID != nil || incomingTabID != nil else { return true }
        guard let incomingTTY else { return true }

        for (otherKey, runtime) in runtimes where otherKey != key {
            guard let runtimeTTY = runtime.tty, runtimeTTY != incomingTTY else { continue }

            if let incomingStableID,
               runtime.terminalStableID == incomingStableID {
                DiagnosticLogger.shared.warning(
                    "Ignored Ghostty terminal id collision key=\(key) stableID=\(incomingStableID) incomingTTY=\(incomingTTY) existingTTY=\(runtimeTTY)"
                )
                return false
            }

            if incomingStableID == nil,
               let incomingTabID,
               runtime.terminalTabID == incomingTabID {
                DiagnosticLogger.shared.warning(
                    "Ignored Ghostty tab id collision key=\(key) tabID=\(incomingTabID) incomingTTY=\(incomingTTY) existingTTY=\(runtimeTTY)"
                )
                return false
            }
        }

        return true
    }

    // MARK: - Private

    private static func isGenericWaitingPreview(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.contains("waiting for your input")
            || normalized.contains("is waiting for your input")
            || normalized == "awaiting your input"
            || normalized == "waiting for input"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
