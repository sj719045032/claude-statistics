import Foundation

/// A plugin that contributes a terminal-emulator adapter (focus return
/// + launching new sessions).
///
/// `descriptor` and `detectInstalled()` are required (the host needs
/// metadata + installation status before it can surface the plugin in
/// any UI). The three behaviour factories (`makeFocusStrategy` /
/// `makeLauncher` / `makeSetupWizard`) are optional — a plugin that
/// only declares the descriptor without a focus strategy still slots
/// into the menu / settings pickers, but the host's focus pipeline
/// falls back to its registered legacy route handler for the
/// matching bundle id.
///
/// Stage 4 migrates the host's existing 8 builtin terminal
/// capabilities to author their plugin via these factories so
/// `TerminalFocusRouteRegistry` and the legacy capability registry can
/// be retired.
public protocol TerminalPlugin: Plugin {
    var descriptor: TerminalDescriptor { get }
    /// Quick best-effort check. Used by the host's Auto-launch picker
    /// and the Settings → Terminal readiness view to skip plugins
    /// whose backing app isn't installed. Default: returns `true`
    /// (the host falls back to existing capability-level checks).
    func detectInstalled() -> Bool

    /// Focus strategy that knows how to put focus inside one of this
    /// terminal's tabs/windows. `nil` means the host should fall back
    /// to its legacy route handler (in v4.0-alpha all builtin plugins
    /// return `nil` and route handlers still drive focus return; v4.1
    /// migrates each to return an owned strategy instance).
    func makeFocusStrategy() -> (any TerminalFocusStrategy)?

    /// Launcher that opens new windows for this terminal. `nil` for
    /// terminals that only handle focus return (e.g. attached editors
    /// invoked via `--goto`).
    func makeLauncher() -> (any TerminalLauncher)?
}

extension TerminalPlugin {
    public func detectInstalled() -> Bool { true }
    public func makeFocusStrategy() -> (any TerminalFocusStrategy)? { nil }
    public func makeLauncher() -> (any TerminalLauncher)? { nil }
}
