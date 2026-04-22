import Foundation

enum CLIFocuser {
    static func contains(
        kind: TerminalCLIKind,
        tty: String?,
        projectPath: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> Bool {
        switch kind {
        case .kitty:
            return containsKitty(
                tty: tty,
                projectPath: projectPath,
                terminalSocket: terminalSocket,
                terminalWindowID: terminalWindowID,
                terminalTabID: terminalTabID,
                stableTerminalID: stableTerminalID
            )
        case .wezterm:
            return containsWezTerm(
                tty: tty,
                projectPath: projectPath,
                stableTerminalID: stableTerminalID
            )
        }
    }

    static func focus(
        kind: TerminalCLIKind,
        tty: String?,
        projectPath: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> Bool {
        switch kind {
        case .kitty:
            return focusKitty(
                tty: tty,
                projectPath: projectPath,
                terminalSocket: terminalSocket,
                terminalWindowID: terminalWindowID,
                terminalTabID: terminalTabID,
                stableTerminalID: stableTerminalID
            )
        case .wezterm:
            return focusWezTerm(tty: tty, projectPath: projectPath, stableTerminalID: stableTerminalID)
        }
    }

    private static func containsKitty(
        tty: String?,
        projectPath: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> Bool {
        guard let kitty = commandPath("kitty") else { return false }
        let socketArgs = terminalSocket?.nilIfEmpty.map { ["--to", $0] } ?? []
        guard let output = run(executable: kitty, arguments: kittyArgs(socketArgs, ["ls"])),
              let data = output.data(using: .utf8),
              let osWindows = try? JSONDecoder().decode([KittyOSWindow].self, from: data)
        else {
            return false
        }

        let ttyVariants = tty.map(ttyVariants) ?? []
        let targetPath = normalizedPath(projectPath)

        for osWindow in osWindows {
            if let terminalWindowID = terminalWindowID?.nilIfEmpty,
               "\(osWindow.id ?? -1)" == terminalWindowID {
                return true
            }
            for tab in osWindow.tabs ?? [] {
                if let terminalTabID = terminalTabID?.nilIfEmpty,
                   "\(tab.id ?? -1)" == terminalTabID {
                    return true
                }
                for window in tab.windows ?? [] {
                    if let stableTerminalID = stableTerminalID?.nilIfEmpty,
                       "\(window.id ?? -1)" == stableTerminalID {
                        return true
                    }

                    let ttyMatches = !ttyVariants.isEmpty && ttyVariants.contains(window.tty ?? "")
                    let cwdMatches = targetPath != nil
                        && targetPath == normalizedPath(window.cwd ?? window.foregroundProcesses?.first?.cwd)
                    if ttyMatches || cwdMatches {
                        return true
                    }
                }
            }
        }

        return false
    }

    private static func containsWezTerm(
        tty: String?,
        projectPath: String?,
        stableTerminalID: String?
    ) -> Bool {
        guard let wezterm = commandPath("wezterm"),
              let output = run(executable: wezterm, arguments: ["cli", "list", "--format", "json"]),
              let data = output.data(using: .utf8),
              let panes = try? JSONDecoder().decode([WezTermPane].self, from: data)
        else {
            return false
        }

        if let stableTerminalID = stableTerminalID?.nilIfEmpty,
           panes.contains(where: { "\($0.paneId)" == stableTerminalID }) {
            return true
        }

        let variants = tty.map(ttyVariants) ?? []
        let targetPath = normalizedPath(projectPath)
        return panes.contains { pane in
            (!variants.isEmpty && variants.contains(pane.ttyName ?? ""))
                || (targetPath != nil && targetPath == normalizedPath(pane.cwd))
        }
    }

    private static func focusKitty(
        tty: String?,
        projectPath: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> Bool {
        guard let kitty = commandPath("kitty") else { return false }
        let socketArgs = terminalSocket?.nilIfEmpty.map { ["--to", $0] } ?? []

        if let terminalTabID = terminalTabID?.nilIfEmpty {
            _ = run(executable: kitty, arguments: kittyArgs(socketArgs, ["focus-tab", "--match", "id:\(terminalTabID)"]))
        }
        if let stableTerminalID = stableTerminalID?.nilIfEmpty,
           run(executable: kitty, arguments: kittyArgs(socketArgs, ["focus-window", "--match", "id:\(stableTerminalID)"])) != nil {
            return true
        }
        if let terminalWindowID = terminalWindowID?.nilIfEmpty,
           run(executable: kitty, arguments: kittyArgs(socketArgs, ["focus-window", "--match", "id:\(terminalWindowID)"])) != nil {
            return true
        }

        guard let output = run(executable: kitty, arguments: kittyArgs(socketArgs, ["ls"])),
              let data = output.data(using: .utf8),
              let osWindows = try? JSONDecoder().decode([KittyOSWindow].self, from: data)
        else {
            return false
        }

        let ttyVariants = tty.map(ttyVariants) ?? []
        let targetPath = normalizedPath(projectPath)

        for osWindow in osWindows {
            for tab in osWindow.tabs ?? [] {
                for window in tab.windows ?? [] {
                    let ttyMatches = ttyVariants.contains(window.tty ?? "")
                    let cwdMatches = targetPath != nil
                        && targetPath == normalizedPath(window.cwd ?? window.foregroundProcesses?.first?.cwd)
                    guard ttyMatches || cwdMatches else { continue }

                    if let tabId = tab.id {
                        _ = run(executable: kitty, arguments: kittyArgs(socketArgs, ["focus-tab", "--match", "id:\(tabId)"]))
                    }
                    if let windowId = window.id,
                       run(executable: kitty, arguments: kittyArgs(socketArgs, ["focus-window", "--match", "id:\(windowId)"])) != nil {
                        return true
                    }
                }
            }
        }

        return false
    }

    private static func focusWezTerm(tty: String?, projectPath: String?, stableTerminalID: String?) -> Bool {
        guard let wezterm = commandPath("wezterm") else { return false }
        if let stableTerminalID = stableTerminalID?.nilIfEmpty,
           run(executable: wezterm, arguments: ["cli", "activate-pane", "--pane-id", stableTerminalID]) != nil {
            return true
        }

        guard let output = run(executable: wezterm, arguments: ["cli", "list", "--format", "json"]),
              let data = output.data(using: .utf8),
              let panes = try? JSONDecoder().decode([WezTermPane].self, from: data)
        else {
            return false
        }

        let variants = tty.map(ttyVariants) ?? []
        let targetPath = normalizedPath(projectPath)
        guard let pane = panes.first(where: { pane in
            variants.contains(pane.ttyName ?? "")
                || (targetPath != nil && targetPath == normalizedPath(pane.cwd))
        }) else { return false }
        _ = run(executable: wezterm, arguments: ["cli", "activate-pane", "--pane-id", "\(pane.paneId)"])
        return true
    }

    private static func kittyArgs(_ socketArgs: [String], _ commandArgs: [String]) -> [String] {
        ["@"] + socketArgs + commandArgs
    }

    private static func commandPath(_ command: String) -> String? {
        if let found = which(command) {
            return found
        }

        let candidates: [String]
        switch command {
        case "kitty":
            candidates = [
                "/Applications/kitty.app/Contents/MacOS/kitty",
                "/opt/homebrew/bin/kitty",
                "/usr/local/bin/kitty"
            ]
        case "wezterm":
            candidates = [
                "/Applications/WezTerm.app/Contents/MacOS/wezterm",
                "/opt/homebrew/bin/wezterm",
                "/usr/local/bin/wezterm"
            ]
        default:
            candidates = []
        }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func which(_ command: String) -> String? {
        run(executable: "/usr/bin/which", arguments: [command])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func run(executable: String, arguments: [String]) -> String? {
        guard let result = TerminalProcessRunner.run(executable: executable, arguments: arguments),
              result.terminationStatus == 0 else {
            return nil
        }
        return result.stdout
    }

    private static func ttyVariants(_ tty: String) -> Set<String> {
        let trimmed = tty.replacingOccurrences(of: "/dev/", with: "")
        return [tty, trimmed, "/dev/\(trimmed)"]
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path = path?.nilIfEmpty else { return nil }
        var resolved = (path as NSString).expandingTildeInPath
        if resolved.hasPrefix("file://"),
           let url = URL(string: resolved) {
            resolved = url.path
        }
        return URL(fileURLWithPath: resolved).standardizedFileURL.path
    }
}

private struct KittyOSWindow: Decodable {
    let id: Int?
    let tabs: [KittyTab]?
}

private struct KittyTab: Decodable {
    let id: Int?
    let windows: [KittyWindow]?
}

private struct KittyWindow: Decodable {
    let id: Int?
    let tty: String?
    let cwd: String?
    let foregroundProcesses: [KittyProcess]?

    enum CodingKeys: String, CodingKey {
        case id
        case tty
        case cwd
        case foregroundProcesses = "foreground_processes"
    }
}

private struct KittyProcess: Decodable {
    let cwd: String?
}

private struct WezTermPane: Decodable {
    let paneId: Int
    let ttyName: String?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id"
        case ttyName = "tty_name"
        case cwd
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
