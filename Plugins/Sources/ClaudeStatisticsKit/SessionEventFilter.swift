import Foundation

/// Snapshot of the signals every active-session filter is allowed to
/// inspect. Constructed by the host from either a fresh `AttentionEvent`
/// or a persisted `RuntimeSession`, so the same filter chain works for
/// both "incoming hook" and "row already on disk after restart" paths.
///
/// New fields land here when filters need them — keep the surface narrow
/// so a third-party filter can't accidentally depend on host internals.
public struct SessionFilterContext: Sendable {
    /// Provider id (matches `ProviderDescriptor.id` / `ProviderKind.rawValue`).
    public let providerId: String
    public let sessionId: String
    /// Latest user-visible prompt for this session, if any. Filters that
    /// need to detect synthetic / templated prompts (e.g. Codex.app's
    /// "Ambient Suggestions" task) read this.
    public let prompt: String?
    public let tty: String?
    public let pid: pid_t?
    /// Hook-reported terminal alias (`TERM_PROGRAM`-style — "iTerm2",
    /// "ghostty", "codex", …). May be `nil` for hosts that fire hooks
    /// without a PTY (Codex.app embedded codex-cli).
    public let terminalName: String?
    public let projectPath: String?

    public init(
        providerId: String,
        sessionId: String,
        prompt: String?,
        tty: String?,
        pid: pid_t?,
        terminalName: String?,
        projectPath: String?
    ) {
        self.providerId = providerId
        self.sessionId = sessionId
        self.prompt = prompt
        self.tty = tty
        self.pid = pid
        self.terminalName = terminalName
        self.projectPath = projectPath
    }
}

/// One node in the host's active-session filter chain. The host runs
/// every registered filter against a context built from each hook
/// event (and against persisted runtime rows on every refresh tick);
/// any filter returning `false` hides the session from "user activity"
/// surfaces — currently the notch session list, more later.
///
/// Filters are intentionally stateless: state belongs to whatever
/// constructed them (a plugin holding its own per-instance config).
/// This lets the host evaluate the same filter across both fresh
/// events and replayed-from-disk runtime without worrying about
/// re-initialisation.
public protocol SessionEventFilter: Sendable {
    /// Stable identifier used in diagnostics / logs (e.g.
    /// `"terminal-focusable"`, `"codex-ambient"`). Reuse across plugins
    /// is fine — it's purely descriptive.
    var id: String { get }

    /// Return `false` to hide the session. The default chain semantics
    /// is logical-AND: the row is visible only when every filter
    /// returns true.
    func shouldDisplay(_ context: SessionFilterContext) -> Bool
}

/// Reusable filter that hides a session whose prompt starts with any
/// of the configured prefixes for the named provider. Plugins describe
/// their own templated/system-injected prompts (Codex.app ambient
/// suggestions, future shell autosuggest probes, …) by constructing
/// one of these — no host code change required.
///
/// Match is `hasPrefix` after a leading-whitespace trim, which covers
/// the common case where the host app pads the synthesised prompt
/// with newlines or framing.
public struct SyntheticPromptFilter: SessionEventFilter {
    public let id: String
    public let providerId: String
    public let prefixes: [String]

    public init(id: String, providerId: String, prefixes: [String]) {
        self.id = id
        self.providerId = providerId
        self.prefixes = prefixes
    }

    public func shouldDisplay(_ context: SessionFilterContext) -> Bool {
        guard context.providerId == providerId else { return true }
        guard let prompt = context.prompt?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return true }
        return !prefixes.contains(where: { prompt.hasPrefix($0) })
    }
}
