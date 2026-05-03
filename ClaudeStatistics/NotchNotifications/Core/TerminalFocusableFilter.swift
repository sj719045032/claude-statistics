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
        // Reject rows with no `terminal_name`. Hook-driven events always
        // arrive with a plugin-resolved name (`HookTerminalResolver`
        // populates it before `WireEventTranslator.makeEvent`, and
        // `AttentionBridge` drops events from hosts no plugin claims at
        // source). A nil here therefore means one of:
        //   (a) disk-persisted orphan from a session whose host had no
        //       installed plugin (e.g. Claude.app / Codex.app sessions
        //       captured before the plugin was installed, or before the
        //       AttentionBridge drop guard existed)
        //   (b) transcript-scanner restore line that no subsequent hook
        //       claimed (cloud agent / ssh / SDK headless sessions)
        //   (c) hook with no `__CFBundleIdentifier` AND no TERM_PROGRAM —
        //       the rare path that previously relied on
        //       `kickOffTerminalNameInference` backfilling. Inference
        //       only succeeds when the resolved bundle id is registered
        //       (i.e. its plugin is installed), in which case the next
        //       refresh writes a non-nil name and the row reappears.
        // None of (a)/(b)/(c) can render a source tag or focus button
        // without a claiming plugin, so hide them.
        guard let name = context.terminalName, !name.isEmpty else { return false }
        return TerminalRegistry.canFocusBackToTerminal(named: name)
    }
}
