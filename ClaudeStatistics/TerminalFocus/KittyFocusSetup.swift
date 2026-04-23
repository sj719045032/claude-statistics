import Foundation

enum KittyFocusSetup {
    struct Status: Equatable {
        let kittyInstalled: Bool
        let configuredSocket: String?
        let configuredSocketAlive: Bool
        let liveSocket: String?

        var isReady: Bool {
            kittyInstalled && configuredSocket != nil && configuredSocketAlive
        }

        var summary: String {
            if isReady {
                return "Precise Kitty focus is ready"
            }
            if !kittyInstalled {
                return "Kitty is not installed"
            }
            if configuredSocket == nil {
                return "Kitty remote-control socket is not configured"
            }
            return "Restart Kitty or reopen a Kitty window to create the live remote-control socket"
        }
    }

    struct InstallResult {
        let changed: Bool
        let backupURL: URL?
    }

    static var configURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".config/kitty/kitty.conf")
    }

    static func status() -> Status {
        let socket = configuredSocket()
        return Status(
            kittyInstalled: TerminalCLICommand.commandPath("kitty") != nil,
            configuredSocket: socket,
            configuredSocketAlive: socket.map(KittyFocuser.socketExists) ?? false,
            liveSocket: socket.flatMap(KittyFocuser.resolvedSocketAddress)
        )
    }

    static func configuredSocket() -> String? {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }
        for rawLine in contents.components(separatedBy: .newlines).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, parts[0] == "listen_on" else { continue }
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value != "none", !value.isEmpty else { return nil }
            return value
        }
        return nil
    }

    static func ensureConfigured() throws -> InstallResult {
        let fileManager = FileManager.default
        let directory = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var contents = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let alreadyAllowsRemoteControl = hasSetting("allow_remote_control", in: contents) { value in
            ["yes", "socket", "socket-only"].contains(value)
        }
        let alreadyHasListenSocket = configuredSocket() != nil
        guard !alreadyAllowsRemoteControl || !alreadyHasListenSocket else {
            return InstallResult(changed: false, backupURL: nil)
        }

        let backupURL: URL?
        if fileManager.fileExists(atPath: configURL.path) {
            backupURL = configURL.deletingLastPathComponent()
                .appendingPathComponent("kitty.conf.claude-stats-backup-\(timestamp())")
            try fileManager.copyItem(at: configURL, to: backupURL!)
        } else {
            backupURL = nil
        }

        if !contents.isEmpty, !contents.hasSuffix("\n") {
            contents += "\n"
        }
        contents += "\n#: Claude Statistics terminal focus\n"
        if !alreadyAllowsRemoteControl {
            contents += "allow_remote_control socket-only\n"
        }
        if !alreadyHasListenSocket {
            contents += "listen_on unix:/tmp/kitty-\(NSUserName())\n"
        }

        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return InstallResult(changed: true, backupURL: backupURL)
    }

    private static func hasSetting(
        _ key: String,
        in contents: String,
        accepts: (String) -> Bool
    ) -> Bool {
        for rawLine in contents.components(separatedBy: .newlines).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, parts[0] == key else { continue }
            return accepts(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return false
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
