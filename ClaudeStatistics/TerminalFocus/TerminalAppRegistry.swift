import Foundation

enum TerminalCLIKind: Equatable, Sendable {
    case kitty
    case wezterm
}

enum TerminalFocusRoute: Equatable, Sendable {
    case appleScript
    case cli(TerminalCLIKind)
    case accessibility
    case activate
}

enum TerminalAppRegistry {
    static func bundleId(forTerminalName terminalName: String?) -> String? {
        guard let normalized = terminalName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty
        else {
            return nil
        }

        switch normalized {
        case "ghostty", "xterm-ghostty":
            return "com.mitchellh.ghostty"
        case "apple_terminal", "terminal", "apple terminal":
            return "com.apple.Terminal"
        case "iterm", "iterm.app", "iterm2":
            return "com.googlecode.iterm2"
        case "wezterm", "wezterm-gui":
            return "com.github.wez.wezterm"
        case "kitty", "xterm-kitty":
            return "net.kovidgoyal.kitty"
        case "warp", "warpstabl", "warpterminal":
            return "dev.warp.Warp-Stable"
        case "alacritty":
            return "org.alacritty"
        case "vscode", "visual studio code", "code":
            return "com.microsoft.VSCode"
        case "vscode-insiders", "code-insiders":
            return "com.microsoft.VSCodeInsiders"
        case "cursor":
            return "com.todesktop.230313mzl4w4u92"
        case "windsurf":
            return "com.exafunction.windsurf"
        case "trae":
            return "com.trae.app"
        case "zed":
            return "dev.zed.Zed"
        default:
            return nil
        }
    }

    static func bundleId(forProcessName processName: String?) -> String? {
        guard let normalized = processName?
            .split(separator: "/")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else {
            return nil
        }

        if normalized.contains("terminal") { return "com.apple.Terminal" }
        if normalized.contains("iterm") { return "com.googlecode.iterm2" }
        if normalized.contains("ghostty") { return "com.mitchellh.ghostty" }
        if normalized.contains("wezterm") { return "com.github.wez.wezterm" }
        if normalized.contains("kitty") { return "net.kovidgoyal.kitty" }
        if normalized.contains("alacritty") { return "org.alacritty" }
        if normalized.contains("warp") { return "dev.warp.Warp-Stable" }
        if normalized == "code" || normalized.contains("visual studio code") { return "com.microsoft.VSCode" }
        if normalized.contains("code - insiders") { return "com.microsoft.VSCodeInsiders" }
        if normalized.contains("cursor") { return "com.todesktop.230313mzl4w4u92" }
        if normalized.contains("windsurf") { return "com.exafunction.windsurf" }
        if normalized.contains("trae") { return "com.trae.app" }
        if normalized.contains("zed") { return "dev.zed.Zed" }
        return nil
    }

    static func route(for bundleId: String?) -> TerminalFocusRoute {
        switch bundleId {
        case "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty":
            return .appleScript
        case "net.kovidgoyal.kitty":
            return .cli(.kitty)
        case "com.github.wez.wezterm":
            return .cli(.wezterm)
        case "io.alacritty", "org.alacritty", "dev.warp.Warp-Stable", "dev.warp.Warp", "co.zeit.hyper":
            return .accessibility
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "com.trae.app":
            return .activate
        case "dev.zed.Zed":
            return .activate
        default:
            return .accessibility
        }
    }

    static func isTerminalProcessName(_ processName: String?) -> Bool {
        bundleId(forProcessName: processName) != nil
    }

    static func isTerminalLikeBundle(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        switch bundleId {
        case "com.apple.Terminal",
             "com.googlecode.iterm2",
             "com.mitchellh.ghostty",
             "net.kovidgoyal.kitty",
             "com.github.wez.wezterm",
             "io.alacritty",
             "org.alacritty",
             "dev.warp.Warp-Stable",
             "dev.warp.Warp",
             "co.zeit.hyper",
             "com.microsoft.VSCode",
             "com.microsoft.VSCodeInsiders",
             "com.todesktop.230313mzl4w4u92",
             "com.exafunction.windsurf",
             "com.trae.app",
             "dev.zed.Zed":
            return true
        default:
            return false
        }
    }

    static func isEditorLikeBundle(_ bundleId: String?) -> Bool {
        switch bundleId {
        case "com.microsoft.VSCode",
             "com.microsoft.VSCodeInsiders",
             "com.todesktop.230313mzl4w4u92",
             "com.exafunction.windsurf",
             "com.trae.app",
             "dev.zed.Zed":
            return true
        default:
            return false
        }
    }
}
