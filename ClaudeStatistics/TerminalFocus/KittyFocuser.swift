import Foundation

enum KittyFocuser {
    static func contains(
        tty: String?,
        projectPath: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> Bool {
        guard let kitty = TerminalCLICommand.commandPath("kitty"),
              let socketArgs = socketArgs(terminalSocket: terminalSocket),
              let output = TerminalCLICommand.run(executable: kitty, arguments: kittyArgs(socketArgs, ["ls"])),
              let data = output.data(using: .utf8),
              let osWindows = try? JSONDecoder().decode([KittyOSWindow].self, from: data)
        else {
            return false
        }

        let ttyVariants = tty.map(TerminalCLICommand.ttyVariants) ?? []
        let targetPath = TerminalCLICommand.normalizedPath(projectPath)

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
                        && targetPath == TerminalCLICommand.normalizedPath(window.cwd ?? window.foregroundProcesses?.first?.cwd)
                    if ttyMatches || cwdMatches {
                        return true
                    }
                }
            }
        }

        return false
    }

    static func focus(
        tty: String?,
        projectPath: String?,
        terminalSocket: String?,
        terminalWindowID: String?,
        terminalTabID: String?,
        stableTerminalID: String?
    ) -> Bool {
        guard let kitty = TerminalCLICommand.commandPath("kitty") else { return false }
        guard let socketArgs = socketArgs(terminalSocket: terminalSocket) else {
            DiagnosticLogger.shared.warning(
                "Kitty focus skipped remote-control because no live socket is available; falling back to app activation"
            )
            return false
        }

        if let terminalTabID = terminalTabID?.nilIfEmpty {
            _ = TerminalCLICommand.run(
                executable: kitty,
                arguments: kittyArgs(socketArgs, ["focus-tab", "--match", "id:\(terminalTabID)"]),
                label: "kitty focus-tab"
            )
        }
        if let stableTerminalID = stableTerminalID?.nilIfEmpty,
           TerminalCLICommand.run(
                executable: kitty,
                arguments: kittyArgs(socketArgs, ["focus-window", "--match", "id:\(stableTerminalID)"]),
                label: "kitty focus-window stable"
           ) != nil {
            return true
        }
        if let terminalWindowID = terminalWindowID?.nilIfEmpty,
           TerminalCLICommand.run(
                executable: kitty,
                arguments: kittyArgs(socketArgs, ["focus-window", "--match", "id:\(terminalWindowID)"]),
                label: "kitty focus-window os"
           ) != nil {
            return true
        }

        guard let output = TerminalCLICommand.run(
                executable: kitty,
                arguments: kittyArgs(socketArgs, ["ls"]),
                label: "kitty ls"
              ),
              let data = output.data(using: .utf8),
              let osWindows = try? JSONDecoder().decode([KittyOSWindow].self, from: data)
        else {
            return false
        }

        let ttyVariants = tty.map(TerminalCLICommand.ttyVariants) ?? []
        let targetPath = TerminalCLICommand.normalizedPath(projectPath)

        for osWindow in osWindows {
            for tab in osWindow.tabs ?? [] {
                for window in tab.windows ?? [] {
                    let ttyMatches = ttyVariants.contains(window.tty ?? "")
                    let cwdMatches = targetPath != nil
                        && targetPath == TerminalCLICommand.normalizedPath(window.cwd ?? window.foregroundProcesses?.first?.cwd)
                    guard ttyMatches || cwdMatches else { continue }

                    if let tabId = tab.id {
                        _ = TerminalCLICommand.run(
                            executable: kitty,
                            arguments: kittyArgs(socketArgs, ["focus-tab", "--match", "id:\(tabId)"]),
                            label: "kitty focus-tab fallback"
                        )
                    }
                    if let windowId = window.id,
                       TerminalCLICommand.run(
                            executable: kitty,
                            arguments: kittyArgs(socketArgs, ["focus-window", "--match", "id:\(windowId)"]),
                            label: "kitty focus-window fallback"
                       ) != nil {
                        return true
                    }
                }
            }
        }

        return false
    }

    static func socketArgs(terminalSocket: String?) -> [String]? {
        if let terminalSocket = terminalSocket?.nilIfEmpty {
            guard let resolvedTerminalSocket = resolvedSocketAddress(terminalSocket) else {
                DiagnosticLogger.shared.warning("Kitty socket unavailable requested=\(terminalSocket)")
                return nil
            }
            if resolvedTerminalSocket != terminalSocket {
                DiagnosticLogger.shared.info("Kitty socket resolved requested=\(terminalSocket) live=\(resolvedTerminalSocket)")
            }
            return ["--to", resolvedTerminalSocket]
        }
        guard let configuredSocket = KittyFocusSetup.configuredSocket() else {
            DiagnosticLogger.shared.warning("Kitty socket unavailable: no configured listen_on socket")
            return nil
        }
        guard let resolvedConfiguredSocket = resolvedSocketAddress(configuredSocket) else {
            DiagnosticLogger.shared.warning("Kitty socket unavailable configured=\(configuredSocket)")
            return nil
        }
        if resolvedConfiguredSocket != configuredSocket {
            DiagnosticLogger.shared.info("Kitty socket resolved configured=\(configuredSocket) live=\(resolvedConfiguredSocket)")
        }
        return ["--to", resolvedConfiguredSocket]
    }

    static func socketExists(_ address: String) -> Bool {
        resolvedSocketAddress(address) != nil
    }

    static func resolvedSocketAddress(_ address: String) -> String? {
        guard address.hasPrefix("unix:") else { return address }
        let rawPath = String(address.dropFirst("unix:".count))
        guard !rawPath.hasPrefix("@") else { return address }

        let resolvedPath = localSocketPath(for: rawPath)
        if FileManager.default.fileExists(atPath: resolvedPath) {
            return "unix:\(resolvedPath)"
        }

        guard let matchedPath = matchingLiveSocketPath(for: resolvedPath) else {
            return nil
        }
        return "unix:\(matchedPath)"
    }

    private static func kittyArgs(_ socketArgs: [String], _ commandArgs: [String]) -> [String] {
        ["@"] + socketArgs + commandArgs
    }

    private static func localSocketPath(for rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return NSTemporaryDirectory() + expanded
    }

    private static func matchingLiveSocketPath(for configuredPath: String) -> String? {
        let url = URL(fileURLWithPath: configuredPath)
        let directoryURL = url.deletingLastPathComponent()
        let baseName = url.lastPathComponent

        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let matches = candidates
            .filter { candidate in
                let name = candidate.lastPathComponent
                return name == baseName || name.hasPrefix(baseName + "-")
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate > rhsDate
            }

        return matches.first?.path
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
