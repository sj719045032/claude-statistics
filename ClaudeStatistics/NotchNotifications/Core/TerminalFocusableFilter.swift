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
        TerminalRegistry.canFocusBackToTerminal(named: context.terminalName)
    }
}
