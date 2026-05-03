import Foundation
import ClaudeStatisticsKit

// MARK: - Hook-side terminal context shim
//
// Historically this file ran every plugin-specific recognition path:
// `if env["KITTY_WINDOW_ID"] != nil { return "kitty" }`, the Ghostty
// frontmost / cwd-match osascript probes, the iTerm
// `ITERM_SESSION_ID` split. All of that hardcoded plugin metadata
// inside the host's hook CLI, which broke the chassis principle —
// adding a new terminal required editing host code.
//
// The hook CLI is now a dumb pipe: it forwards `__CFBundleIdentifier`
// + the relevant slice of `ProcessInfo.processInfo.environment` raw
// to the host (see `HookCLI.baseMessage`). The host's
// `HookTerminalResolver` (running on the main actor against the live
// plugin registry) is the single place that decides which plugin the
// row belongs to. Each terminal plugin authors its own
// `TerminalEnvIdentification` and optional `TerminalContextEnriching`
// instead of having the host carry "kitty/wezterm/iterm/ghostty"
// branches.
//
// Free functions kept here are now near-trivial wrappers, retained
// only because `ClaudeHookNormalizer` and the Codex/Gemini plugin
// normalizers (via `HookHelperContext`) still call them. Removing the
// wrappers entirely is a follow-up; they're harmless no-ops in the
// new flow.

/// Identity passthrough — the host re-derives the canonical name on
/// receipt using plugin descriptors. Kept as a function so the
/// existing `terminalName` plumbing in `ClaudeHookNormalizer` doesn't
/// need to change.
func canonicalTerminalName(_ terminalName: String?) -> String? {
    terminalName
}

func terminalContextForClaude(event: String, terminalName: String?, cwd: String?) -> TerminalContext {
    TerminalContext()
}

/// Empty-context passthrough used by `HookHelperContext.detectTerminalContext`.
/// The host fills in socket / surface / window / tab fields after
/// receiving the message — see `HookTerminalResolver`.
func terminalContext(
    event: String,
    terminalName: String?,
    cwd: String?
) -> TerminalContext {
    TerminalContext()
}

func currentTTY(pid: Int) -> String? {
    if let tty = normalizeTTY(ttyname(FileHandle.standardInput.fileDescriptor)) {
        return tty
    }

    if let envTTY = normalizeTTY(ProcessInfo.processInfo.environment["TTY"]) {
        return envTTY
    }

    guard let output = commandOutput("/bin/ps", args: ["-o", "tty=", "-p", String(pid)], timeout: 0.5) else {
        return nil
    }
    return normalizeTTY(output)
}

private func normalizeTTY(_ value: UnsafePointer<CChar>?) -> String? {
    guard let value else { return nil }
    return normalizeTTY(String(cString: value))
}

private func normalizeTTY(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "??", trimmed != "-" else { return nil }
    return trimmed.hasPrefix("/dev/") ? trimmed : "/dev/\(trimmed)"
}
