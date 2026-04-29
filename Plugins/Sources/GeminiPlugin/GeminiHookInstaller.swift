import Foundation
import ClaudeStatisticsKit

struct GeminiHookInstaller: HookInstalling {
    let providerId: String = "gemini"

    private static let scriptName = "claude-stats-gemini-hook"
    private static let managedMarkers = [
        "claude-stats-gemini-hook",
        "claude-stats-hook",
        "--claude-stats-hook-provider"
    ]

    // Per Gemini's hook reference, "ToolPermission" is a `notification_type`
    // value inside Notification events, NOT an event name on its own. The
    // permission notification still fires through the Notification hook.
    private let supportedHookEvents = [
        "BeforeAgent",
        "BeforeTool",
        "BeforeToolSelection",
        "BeforeModel",
        "AfterTool",
        "AfterModel",
        "AfterAgent",
        "SessionStart",
        "SessionEnd",
        "PreCompress",
        "Notification",
    ]

    private var geminiDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".gemini")
    }

    private var hooksDir: String {
        (geminiDir as NSString).appendingPathComponent("hooks")
    }

    private var settingsPath: String {
        (geminiDir as NSString).appendingPathComponent("settings.json")
    }

    private var scriptPath: String {
        (hooksDir as NSString).appendingPathComponent("\(Self.scriptName).py")
    }

    private var commandPath: String {
        HookInstallerUtils.currentHookCommand(providerId: providerId)
    }

    var isInstalled: Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }

        // We check if ALL supported events have the EXACT current command.
        // If even one is missing or has an old path/quoting, we treat it as 
        // not installed so that `install()` will refresh everything.
        let targetCommand = commandPath
        for event in supportedHookEvents {
            guard let definitions = hooks[event] as? [[String: Any]] else { return false }
            
            var foundExactMatch = false
            for definition in definitions {
                guard let inner = definition["hooks"] as? [[String: Any]] else { continue }
                if inner.contains(where: { ($0["command"] as? String) == targetCommand }) {
                    foundExactMatch = true
                    break
                }
            }
            if !foundExactMatch { return false }
        }

        return true
    }

    func install() async throws -> HookInstallResult {
        let snapshots = [
            FileSnapshot.capture(at: settingsPath),
            FileSnapshot.capture(at: scriptPath),
        ]

        do {
            var root = try readSettingsJSON() ?? [:]
            var hooks = root["hooks"] as? [String: Any] ?? [:]

            pruneManagedHooks(from: &hooks)

            for event in supportedHookEvents {
                var definitions = hooks[event] as? [[String: Any]] ?? []
                definitions.append([
                    "hooks": [[
                        "type": "command",
                        "command": commandPath,
                    ]]
                ])
                hooks[event] = definitions
            }

            root["hooks"] = hooks
            try writeSettingsJSON(root)
            HookInstallerUtils.removeScript(at: scriptPath)
        } catch {
            for snapshot in snapshots {
                try? snapshot.restore()
            }
            throw error
        }

        return .success
    }

    func uninstall() async throws -> HookInstallResult {
        let snapshots = [
            FileSnapshot.capture(at: settingsPath),
            FileSnapshot.capture(at: scriptPath),
        ]

        do {
            HookInstallerUtils.removeScript(at: scriptPath)
            guard FileManager.default.fileExists(atPath: settingsPath) else {
                return .success
            }

            guard var root = try readSettingsJSON(),
                  var hooks = root["hooks"] as? [String: Any] else {
                throw HookError.jsonParseError
            }

            pruneManagedHooks(from: &hooks)
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }

            try writeSettingsJSON(root)
        } catch {
            for snapshot in snapshots {
                try? snapshot.restore()
            }
            throw error
        }

        return .success
    }

    private func readSettingsJSON() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsPath) else {
            return nil
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.jsonParseError
        }
        return root
    }

    private func writeSettingsJSON(_ root: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: geminiDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    private func pruneManagedHooks(from hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard let definitions = value as? [[String: Any]] else { continue }
            let sanitized = definitions.compactMap { definition -> [String: Any]? in
                guard let inner = definition["hooks"] as? [[String: Any]] else {
                    return definition
                }

                let retained = inner.filter { !Self.isManagedCommand($0["command"] as? String ?? "") }
                guard !retained.isEmpty else { return nil }

                var updated = definition
                updated["hooks"] = retained
                return updated
            }

            if sanitized.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = sanitized
            }
        }
    }

    private static func isManagedCommand(_ command: String) -> Bool {
        managedMarkers.contains { command.contains($0) }
    }
}
