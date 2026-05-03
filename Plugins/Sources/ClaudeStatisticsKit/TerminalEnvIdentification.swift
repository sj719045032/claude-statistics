import Foundation

/// Plugin-authored description of how a terminal can be recognised
/// from a child-process environment, plus how to extract its tab /
/// window / surface ids out of that env.
///
/// Each terminal that emits identifying env vars (Kitty exports
/// `KITTY_WINDOW_ID`, WezTerm exports `WEZTERM_PANE`, iTerm2 exports
/// `ITERM_SESSION_ID`, etc.) declares a `TerminalEnvIdentification`
/// from its plugin and the host walks every conformer at hook time
/// to figure out which terminal a CLI session is running under. This
/// replaces the host-side `if env["KITTY_WINDOW_ID"] != nil { ... }`
/// hardcoding that previously lived in `TerminalContextDetector`.
public struct TerminalEnvIdentification: Sendable {
    /// Env vars whose presence signals the terminal hosts the current
    /// process. Any one matching is sufficient. Order doesn't matter.
    public let envVars: [String]
    /// Canonical name written into hook payloads (e.g. `"kitty"`).
    /// Should match one of the descriptor's `terminalNameAliases` so
    /// downstream `TerminalRegistry.bundleId(forTerminalName:)`
    /// continues to resolve cleanly.
    public let canonicalName: String
    /// Env var carrying the terminal's IPC socket / control endpoint.
    /// `nil` when the terminal doesn't expose one.
    public let socketEnv: String?
    /// Env var carrying a per-surface (pane / split / terminal cell)
    /// stable id. The most useful field for focus return.
    public let surfaceEnv: String?
    /// Env var carrying the window id, when distinct from surface.
    public let windowEnv: String?
    /// Env var carrying the tab id, when distinct from surface.
    public let tabEnv: String?
    /// Optional transform applied to `surfaceEnv`'s value before it
    /// goes downstream. iTerm2's `ITERM_SESSION_ID` is shaped as
    /// `<profile>:<surface-uuid>` and only the trailing component is
    /// stable across reloads, so the iTerm plugin supplies a transform
    /// that returns the trailing piece.
    public let surfaceTransform: (@Sendable (String) -> String?)?

    public init(
        envVars: [String],
        canonicalName: String,
        socketEnv: String? = nil,
        surfaceEnv: String? = nil,
        windowEnv: String? = nil,
        tabEnv: String? = nil,
        surfaceTransform: (@Sendable (String) -> String?)? = nil
    ) {
        self.envVars = envVars
        self.canonicalName = canonicalName
        self.socketEnv = socketEnv
        self.surfaceEnv = surfaceEnv
        self.windowEnv = windowEnv
        self.tabEnv = tabEnv
        self.surfaceTransform = surfaceTransform
    }
}

/// Plugin opt-in protocol for env-based terminal recognition. Plugins
/// don't have to conform — those without identifying env vars (e.g.
/// Ghostty, Apple Terminal) simply rely on the descriptor's
/// `terminalNameAliases` matching `TERM_PROGRAM`/`TERM`, which the
/// host already handles through `TerminalRegistry.bundleId(forTerminalName:)`.
///
/// Adding a new conformer is the only change required when a new
/// terminal grows its own identification env var; the host walks every
/// conformer in registry order and picks the first match.
public protocol TerminalEnvIdentifying {
    var envIdentification: TerminalEnvIdentification { get }
}
