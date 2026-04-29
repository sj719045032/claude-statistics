import Foundation

/// Manages the Codex terminal status line configuration in ~/.codex/config.toml
struct CodexStatusLineInstaller {
    static let configPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/config.toml")
    static let backupPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/status-line-config.toml.bak")

    /// Recommended layout preset — mirrors the user's preferred config
    static let presetItems: [String] = [
        "model-with-reasoning", "current-dir", "git-branch", "context-usage",
        "five-hour-limit", "weekly-limit", "context-window-size",
        "total-input-tokens", "total-output-tokens",
    ]

    private static let usageComponents: Set<String> = ["five-hour-limit", "weekly-limit"]

    /// True when config.toml's status_line includes both usage components
    static var isInstalled: Bool {
        guard let items = readStatusLineItems() else { return false }
        return usageComponents.isSubset(of: Set(items))
    }

    static var hasBackup: Bool {
        FileManager.default.fileExists(atPath: backupPath)
    }

    /// Write the full preset to config.toml's [tui].status_line
    static func install() throws {
        let fm = FileManager.default
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            throw CodexStatusLineError.configNotFound
        }

        if !isInstalled && !fm.fileExists(atPath: backupPath) {
            try content.write(toFile: backupPath, atomically: true, encoding: .utf8)
        }

        let newLine = formatStatusLine(presetItems)
        var lines = content.components(separatedBy: "\n")

        if let idx = lines.firstIndex(where: { isStatusLineLine($0) }) {
            lines[idx] = newLine
        } else if let tuiIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[tui]" }) {
            lines.insert(newLine, at: tuiIdx + 1)
        } else {
            lines.append("")
            lines.append("[tui]")
            lines.append(newLine)
        }

        content = lines.joined(separator: "\n")
        try content.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    static func restore() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: backupPath) {
            if fm.fileExists(atPath: configPath) {
                try fm.removeItem(atPath: configPath)
            }
            try fm.copyItem(atPath: backupPath, toPath: configPath)
            try fm.removeItem(atPath: backupPath)
            return
        }

        // If no backup exists, still allow the user to turn the integration off.
        // Preserve non-ClaudeStatistics status-line items instead of deleting the
        // whole config.toml or blocking the toggle.
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            throw CodexStatusLineError.configNotFound
        }

        var lines = content.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { isStatusLineLine($0) }) else { return }

        let currentItems = readStatusLineItems(from: lines[idx]) ?? []
        let remaining = currentItems.filter { !usageComponents.contains($0) }
        if remaining.isEmpty {
            lines.remove(at: idx)
        } else {
            lines[idx] = formatStatusLine(remaining)
        }

        content = lines.joined(separator: "\n")
        try content.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Private

    private static func readStatusLineItems() -> [String]? {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: "\n") {
            if let items = readStatusLineItems(from: line) { return items }
        }
        return nil
    }

    private static func readStatusLineItems(from line: String) -> [String]? {
        guard isStatusLineLine(line),
              let start = line.firstIndex(of: "["),
              let end = line.lastIndex(of: "]"),
              start < end
        else { return nil }

        let inner = String(line[line.index(after: start)..<end])
        return inner.components(separatedBy: ",").compactMap { token -> String? in
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 else { return nil }
            return String(t.dropFirst().dropLast())
        }
    }

    private static func isStatusLineLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("status_line") && t.contains("=")
    }

    private static func formatStatusLine(_ items: [String]) -> String {
        "status_line = [\(items.map { "\"\($0)\"" }.joined(separator: ", "))]"
    }
}

enum CodexStatusLineError: LocalizedError {
    case configNotFound
    case noBackup

    var errorDescription: String? {
        switch self {
        case .configNotFound:
            return "~/.codex/config.toml not found. Run `codex` at least once to initialize it."
        case .noBackup:
            return "No Codex status line backup found."
        }
    }
}
