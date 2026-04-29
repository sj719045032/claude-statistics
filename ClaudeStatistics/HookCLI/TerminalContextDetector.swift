import Foundation
import ClaudeStatisticsKit

// MARK: - Terminal Context Detector
func canonicalTerminalName(_ terminalName: String?) -> String? {
    let env = ProcessInfo.processInfo.environment
    if env["KITTY_WINDOW_ID"] != nil || env["KITTY_LISTEN_ON"] != nil {
        return "kitty"
    }
    if env["WEZTERM_PANE"] != nil || env["WEZTERM_UNIX_SOCKET"] != nil {
        return "wezterm"
    }
    if env["ITERM_SESSION_ID"] != nil {
        return "iTerm2"
    }
    return terminalName
}

func terminalContextForCodex(event: String, terminalName: String?, cwd: String?) -> TerminalContext {
    terminalContext(
        event: event,
        terminalName: terminalName,
        cwd: cwd,
        ghosttyFrontmostEvents: ["SessionStart", "UserPromptSubmit"],
        ghosttyFallbackMode: .uniqueDirectoryMatch
    )
}

func terminalContextForClaude(event: String, terminalName: String?, cwd: String?) -> TerminalContext {
    terminalContext(
        event: event,
        terminalName: terminalName,
        cwd: cwd,
        ghosttyFrontmostEvents: ["SessionStart", "UserPromptSubmit"],
        ghosttyFallbackMode: .uniqueDirectoryMatch
    )
}

// `terminalContextForGemini` removed — Gemini's normalizer lives in
// `Plugins/Sources/GeminiPlugin/` and reaches the same logic through
// `HookHelperContext.detectTerminalContext`.

enum GhosttyFallbackMode {
    case disabled
    case uniqueDirectoryMatch
}

func terminalContext(
    event: String,
    terminalName: String?,
    cwd: String?,
    ghosttyFrontmostEvents: Set<String>,
    ghosttyFallbackMode: GhosttyFallbackMode
) -> TerminalContext {
    let env = ProcessInfo.processInfo.environment
    let normalized = (terminalName ?? "").lowercased()

    if env["KITTY_WINDOW_ID"] != nil || env["KITTY_LISTEN_ON"] != nil {
        return TerminalContext(
            socket: env["KITTY_LISTEN_ON"],
            windowID: nil,
            tabID: nil,
            surfaceID: env["KITTY_WINDOW_ID"]
        )
    }

    if env["WEZTERM_PANE"] != nil || env["WEZTERM_UNIX_SOCKET"] != nil {
        return TerminalContext(
            socket: env["WEZTERM_UNIX_SOCKET"],
            windowID: nil,
            tabID: nil,
            surfaceID: env["WEZTERM_PANE"]
        )
    }

    if normalized.contains("iterm") {
        let session = env["ITERM_SESSION_ID"] ?? ""
        let stableID = session.split(separator: ":", maxSplits: 1).last.map(String.init)
        return TerminalContext(socket: nil, windowID: nil, tabID: nil, surfaceID: stableID)
    }

    if normalized.contains("kitty") {
        return TerminalContext(
            socket: env["KITTY_LISTEN_ON"],
            windowID: nil,
            tabID: nil,
            surfaceID: env["KITTY_WINDOW_ID"]
        )
    }

    if normalized.contains("wezterm") {
        return TerminalContext(
            socket: env["WEZTERM_UNIX_SOCKET"],
            windowID: nil,
            tabID: nil,
            surfaceID: env["WEZTERM_PANE"]
        )
    }

    guard normalized.contains("ghostty") else {
        return TerminalContext()
    }

    if ghosttyFrontmostEvents.contains(event),
       let frontmost = ghosttyFrontmostContext(cwd: cwd, requireFrontmostApp: false) {
        return frontmost
    }

    guard ghosttyFallbackMode == .uniqueDirectoryMatch else {
        return TerminalContext()
    }

    return ghosttyUniqueDirectoryMatch(cwd: cwd) ?? TerminalContext()
}

private func ghosttyFrontmostContext(cwd: String?, requireFrontmostApp: Bool) -> TerminalContext? {
    let frontmostGuard = requireFrontmostApp ? "if not frontmost then return \"\"\n    " : ""
    let script = """
    tell application id "com.mitchellh.ghostty"
        \(frontmostGuard)try
            set w to front window
            set tabRef to selected tab of w
            set terminalRef to focused terminal of tabRef
            set outputLine to (id of w as text) & (ASCII character 31) & (id of tabRef as text) & (ASCII character 31) & (id of terminalRef as text) & (ASCII character 31) & (working directory of terminalRef as text)
            return outputLine
        end try
    end tell
    return ""
    """

    let diag = commandOutputDiagnostic("/usr/bin/osascript", args: ["-e", script])
    guard let output = diag.stdout, diag.exitCode == 0 else {
        hookGhosttyLog("frontmost osascript failed cwd=\(cwd ?? "-") requireFrontmost=\(requireFrontmostApp) exit=\(diag.exitCode.map(String.init) ?? "-") stderr=\(diag.stderr.debugDescription)")
        return nil
    }

    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: "\u{1F}", omittingEmptySubsequences: false)
    guard parts.count == 4 else {
        hookGhosttyLog("frontmost parse mismatch fields=\(parts.count) raw=\(trimmed.debugDescription)")
        return nil
    }

    let resolvedCWD = normalizePath(cwd)
    let resolvedTerminalCWD = normalizePath(String(parts[3]))
    guard resolvedTerminalCWD == resolvedCWD else {
        hookGhosttyLog(
            "frontmost cwd mismatch hook=\(resolvedCWD ?? "-") ghostty=\(resolvedTerminalCWD ?? "-") raw=\(String(parts[3]).debugDescription)"
        )
        return nil
    }

    hookGhosttyLog("frontmost matched window=\(String(parts[0])) tab=\(String(parts[1])) stable=\(String(parts[2])) cwd=\(resolvedTerminalCWD ?? "-")")
    return TerminalContext(
        socket: nil,
        windowID: nonEmpty(String(parts[0])),
        tabID: nonEmpty(String(parts[1])),
        surfaceID: nonEmpty(String(parts[2]))
    )
}

private func ghosttyUniqueDirectoryMatch(cwd: String?) -> TerminalContext? {
    let script = """
    tell application id "com.mitchellh.ghostty"
        set outputLines to {}
        repeat with w in every window
            set windowID to id of w as text
            repeat with tabRef in every tab of w
                set tabID to id of tabRef as text
                set terminalRef to focused terminal of tabRef
                set terminalID to id of terminalRef as text
                set terminalWD to working directory of terminalRef as text
                set end of outputLines to windowID & (ASCII character 31) & tabID & (ASCII character 31) & terminalID & (ASCII character 31) & terminalWD
            end repeat
        end repeat
        set AppleScript's text item delimiters to linefeed
        set outputText to outputLines as text
        set AppleScript's text item delimiters to ""
        return outputText
    end tell
    """

    guard let output = commandOutput("/usr/bin/osascript", args: ["-e", script]) else {
        hookGhosttyLog("unique cwd scan returned no output cwd=\(cwd ?? "-")")
        return nil
    }

    let target = normalizePath(cwd)
    var matches: [TerminalContext] = []
    for line in output.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
        guard parts.count == 4 else { continue }
        guard normalizePath(String(parts[3])) == target else { continue }
        matches.append(
            TerminalContext(
                socket: nil,
                windowID: nonEmpty(String(parts[0])),
                tabID: nonEmpty(String(parts[1])),
                surfaceID: nonEmpty(String(parts[2]))
            )
        )
    }

    hookGhosttyLog("unique cwd scan target=\(target ?? "-") matches=\(matches.count)")
    return matches.count == 1 ? matches[0] : nil
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

private func normalizePath(_ value: String?) -> String? {
    guard let value else { return nil }
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }

    if text.hasPrefix("file://") {
        if let decoded = URL(string: text)?.path.removingPercentEncoding {
            text = decoded
        } else {
            text = String(text.dropFirst(7))
        }
    }

    return URL(fileURLWithPath: text)
        .resolvingSymlinksInPath()
        .standardizedFileURL
        .path
}
