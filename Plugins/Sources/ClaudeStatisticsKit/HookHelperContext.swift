import Foundation

/// Host-implemented bridge plugins use to access main-binary-only
/// concerns from inside their `ProviderHookNormalizing` body —
/// notably the auth token and TTY probe that depend on host runtime
/// state plugins don't see. The pure-data helpers (`stringValue`,
/// `firstText`, `toolNameValue`, …) stay as free SDK functions.
///
/// Why this is a protocol instead of static functions: the
/// `auth_token` lookup reaches into the host's `AttentionBridgeAuth`
/// keychain stub, which runs only in the main binary. Modeling that
/// as a host-supplied object rather than a global function lets the
/// host pass mocks under test, and keeps plugins from accidentally
/// crashing when called outside the HookCLI fast-path.
public protocol HookHelperContext {
    /// Compose the standard wire-message header every provider's hook
    /// pipeline emits. Sets `v` / `auth_token` / `provider` / `event`
    /// / `status` / `pid` / `expects_response`, then folds in the
    /// non-nil values for `notification_type` / `session_id` / `cwd`
    /// / `transcript_path` / `tty` / `terminal_*`.
    func baseMessage(
        providerId: String,
        event: String,
        status: String,
        notificationType: String?,
        payload: [String: Any],
        cwd: String?,
        terminalName: String?,
        terminalContext: HookTerminalContext
    ) -> [String: Any]

    /// Resolved CWD: payload field → `$PWD` env → process CWD. Used
    /// before `baseMessage` so plugins fill the locator argument and
    /// then hand the same value into `baseMessage`'s `cwd:` field.
    func resolvedHookCWD(payload: [String: Any]) -> String?

    /// Coalesces `TERM_PROGRAM` / `TERM` env into the canonical
    /// terminal app name (e.g. "kitty" / "wezterm" / "iTerm2") that
    /// the rest of the focus pipeline indexes by.
    func canonicalTerminalName(_ raw: String?) -> String?

    /// Sniff socket / window / tab / surface ids for the live
    /// terminal hosting this hook invocation. `ghosttyFrontmostEvents`
    /// names the events for which a Ghostty-frontmost AppleScript
    /// probe is allowed to run — different providers have different
    /// "this event must be the user's foreground action" rules.
    func detectTerminalContext(
        event: String,
        terminalName: String?,
        cwd: String?,
        ghosttyFrontmostEvents: Set<String>
    ) -> HookTerminalContext
}
