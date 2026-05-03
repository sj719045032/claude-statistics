import Foundation

/// Plugin opt-in for *dynamic* terminal-context enrichment — i.e.
/// reading something out of the running terminal app (AppleScript,
/// IPC socket, etc.) instead of the child-process env. Used for
/// terminals like Ghostty that don't export a per-surface env var
/// but expose enough scripting to walk their windows and pick the
/// one whose working directory matches the hook's cwd.
///
/// The host calls `enrichContext` after env-based identification has
/// resolved the terminal but the resulting `HookTerminalContext` is
/// still empty (no socket / surface id). A `nil` return is fine —
/// the host falls back to the descriptor-only context.
public protocol TerminalContextEnriching {
    /// - Parameters:
    ///   - event: The hook event name (`"SessionStart"`, `"PreToolUse"`,
    ///     etc.). Plugins can gate expensive probes to a subset of
    ///     events so e.g. the per-tool hook firehose doesn't spam
    ///     osascript.
    ///   - cwd: The hook's resolved current working directory.
    ///     Plugins typically use this to disambiguate which of several
    ///     open windows actually hosts this session.
    ///   - env: The transmitted hook env (the same dictionary the host
    ///     used for env-based identification). Plugins read whatever
    ///     extra keys they need from this — passing the env through
    ///     keeps enrichers self-contained without a separate lookup
    ///     channel.
    ///
    /// Implementations should be safe to call from a non-main actor
    /// (the host invokes them on a background dispatch queue while
    /// processing socket messages).
    func enrichContext(
        event: String,
        cwd: String?,
        env: [String: String]
    ) -> HookTerminalContext?
}
