import ClaudeStatisticsKit
import Foundation

/// Host-internal `SessionEventFilter` that hides rows whose hook
/// `terminal_name` doesn't resolve to any registered terminal capability
/// or plugin alias — i.e. the click handler has nowhere to land. Lives
/// in the host bundle (rather than the SDK) because it dispatches
/// through `TerminalRegistry`, which holds the kernel's identity tables.
struct TerminalFocusableFilter: SessionEventFilter {
    let id = "terminal-focusable"

    func shouldDisplay(_ context: SessionFilterContext) -> Bool {
        // Restore-warmed rows arrive from session metadata with no
        // terminal_name yet — the next hook event fills it. Tolerate the
        // unknown state so the row survives until then; only reject when
        // a name *was* provided and didn't resolve.
        guard let name = context.terminalName, !name.isEmpty else { return true }
        return TerminalRegistry.canFocusBackToTerminal(named: name)
    }
}
