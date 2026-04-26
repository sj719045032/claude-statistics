import Foundation

/// Plugin contribution that opens a new terminal window/tab targeting the
/// directory + initial command described by `TerminalLaunchRequest`.
///
/// Each `TerminalPlugin` may declare an optional `TerminalLauncher`. The
/// host's launch coordinator picks one based on user preference and
/// availability — first the user's preferred terminal id, then the
/// auto-selection priority order (lowest `autoLaunchPriority` wins),
/// then a hard-coded fallback to `Terminal.app`.
///
/// The protocol is fire-and-forget. Concrete implementations should:
/// - Best-effort report failure via `DiagnosticLogger` rather than
///   throwing — the host has no fallback chain at the call site.
/// - Quote / escape the working directory and command in whatever shell
///   their target terminal expects.
/// - Use `Process` / `NSWorkspace` rather than blocking on AppleScript.
public protocol TerminalLauncher: Sendable {
    func launch(_ request: TerminalLaunchRequest)
}
