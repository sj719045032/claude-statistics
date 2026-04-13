import Foundation

/// Manages the Codex terminal status line configuration in ~/.codex/config.toml
struct CodexStatusLineInstaller {
    static let configPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/config.toml")

    /// Recommended layout preset — mirrors the user's preferred config
    static let presetItems: [String] = [
        "model-with-reasoning", "current-dir", "git-branch", "context-usage",
        "five-hour-limit", "weekly-limit", "codex-version", "context-window-size",
    ]

    private static let usageComponents: Set<String> = ["five-hour-limit", "weekly-limit"]

    /// True when config.toml's status_line includes both usage components
    static var isInstalled: Bool {
        guard let items = readStatusLineItems() else { return false }
        return usageComponents.isSubset(of: Set(items))
    }

    /// Write the full preset to config.toml's [tui].status_line
    static func install() throws {
        guard var content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            throw CodexStatusLineError.configNotFound
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

    // MARK: - Private

    private static func readStatusLineItems() -> [String]? {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: "\n") {
            guard isStatusLineLine(line),
                  let start = line.firstIndex(of: "["),
                  let end = line.lastIndex(of: "]"),
                  start < end
            else { continue }

            let inner = String(line[line.index(after: start)..<end])
            let items = inner.components(separatedBy: ",").compactMap { token -> String? in
                let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 else { return nil }
                return String(t.dropFirst().dropLast())
            }
            return items
        }
        return nil
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

    var errorDescription: String? {
        "~/.codex/config.toml not found. Run `codex` at least once to initialize it."
    }
}
