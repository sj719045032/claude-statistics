import Foundation

/// What level of focus return a strategy can deliver for a given target.
/// Used by the host to gate UI prompts ("set up <terminal>" callouts) and
/// to decide whether to short-circuit to a less-precise fallback.
public enum TerminalFocusCapability: Equatable, Sendable {
    /// The strategy can land focus inside the exact tab/window of the
    /// target session.
    case ready
    /// The strategy can only activate the app — tab-level navigation is
    /// the user's responsibility.
    case appOnly
    /// The strategy needs the macOS Accessibility permission to operate.
    /// Host UI surfaces a one-time prompt before retrying.
    case requiresAccessibility
    /// Capability hasn't been probed yet for this target.
    case unresolved
}

/// Address of a terminal location the host needs to put focus on. Captured
/// at hook-fire time and replayed when the user clicks an island card.
///
/// The shape carries more identity hints than any single strategy uses —
/// AppleScript-driven terminals key off `bundleId` + `terminalTabID`,
/// Kitty / WezTerm key off `terminalSocket` + a strategy-specific window
/// id, Ghostty keys off `terminalStableID` (its surface id), and
/// projection-based fallbacks key off `tty` / `projectPath`. Strategies
/// pick whichever fields they recognise and ignore the rest.
public struct TerminalFocusTarget: Equatable, Sendable {
    public let terminalPid: pid_t?
    public let bundleId: String?
    public let tty: String?
    public let projectPath: String?
    public let terminalName: String?
    public let terminalSocket: String?
    public let terminalWindowID: String?
    public let terminalTabID: String?
    public let terminalStableID: String?
    /// Provider-side session identifier (matches `Session.id`). Carried
    /// through so deep-link strategies (e.g. chat-app plugins that route
    /// `claude://claude.ai/resume?session=<id>` or `codex://threads/<id>`)
    /// can address a specific conversation rather than just activating
    /// the app. Strategies that focus on terminal tabs ignore it.
    public let sessionId: String?
    public let capability: TerminalFocusCapability
    public let capturedAt: Date

    public init(
        terminalPid: pid_t?,
        bundleId: String?,
        tty: String?,
        projectPath: String?,
        terminalName: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        terminalStableID: String?,
        sessionId: String? = nil,
        capability: TerminalFocusCapability,
        capturedAt: Date
    ) {
        self.terminalPid = terminalPid
        self.bundleId = bundleId
        self.tty = tty
        self.projectPath = projectPath
        self.terminalName = terminalName
        self.terminalSocket = terminalSocket
        self.terminalWindowID = terminalWindowID
        self.terminalTabID = terminalTabID
        self.terminalStableID = terminalStableID
        self.sessionId = sessionId
        self.capability = capability
        self.capturedAt = capturedAt
    }

    public var hasStableLocator: Bool {
        bundleId != nil && (terminalStableID != nil || terminalTabID != nil || terminalWindowID != nil || projectPath != nil)
    }

    /// Whether the captured target is fresh enough to act on. PID-keyed
    /// targets expire fast (30s) because OS recycles pids; stable-id
    /// targets get 30 minutes because they survive across processes.
    public func isUsable(pidKnown: Bool) -> Bool {
        let age = Date().timeIntervalSince(capturedAt)
        if pidKnown {
            return age < 30
        }
        return age < (hasStableLocator ? 1800 : 30)
    }

    public func withStableTerminalID(
        _ stableTerminalID: String?,
        capturedAt: Date = Date()
    ) -> TerminalFocusTarget {
        TerminalFocusTarget(
            terminalPid: terminalPid,
            bundleId: bundleId,
            tty: tty,
            projectPath: projectPath,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: terminalWindowID,
            terminalTabID: terminalTabID,
            terminalStableID: stableTerminalID,
            sessionId: sessionId,
            capability: capability,
            capturedAt: capturedAt
        )
    }

    public func clearingTerminalIdentity(
        capturedAt: Date = Date()
    ) -> TerminalFocusTarget {
        TerminalFocusTarget(
            terminalPid: terminalPid,
            bundleId: bundleId,
            tty: tty,
            projectPath: projectPath,
            terminalName: terminalName,
            terminalSocket: terminalSocket,
            terminalWindowID: nil,
            terminalTabID: nil,
            terminalStableID: nil,
            sessionId: sessionId,
            capability: capability,
            capturedAt: capturedAt
        )
    }
}

/// Lightweight terminal-process descriptor used by the focus pipeline to
/// pair a captured pid with its bundle id.
public struct TerminalProcess: Equatable, Sendable {
    public let pid: pid_t
    public let bundleId: String?

    public init(pid: pid_t, bundleId: String?) {
        self.pid = pid
        self.bundleId = bundleId
    }
}

/// Outcome of one strategy invocation. `capability` reflects what the
/// strategy can do for this target now (post-attempt — e.g. AX permission
/// just granted). `resolvedStableID` lets the strategy report a freshly
/// learnt stable id back to the host so future invocations skip the
/// resolve step.
public struct TerminalFocusExecutionResult: Sendable {
    public let capability: TerminalFocusCapability
    public let resolvedStableID: String?

    public init(capability: TerminalFocusCapability, resolvedStableID: String?) {
        self.capability = capability
        self.resolvedStableID = resolvedStableID
    }
}
