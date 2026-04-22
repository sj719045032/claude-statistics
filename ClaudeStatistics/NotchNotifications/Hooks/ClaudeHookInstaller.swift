import Foundation

struct ClaudeHookInstaller: HookInstalling {
    let provider: ProviderKind = .claude

    private static let scriptName     = "claude-stats-claude-hook"
    private static let managedMarker  = "claude-stats-"

    private var hooksDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/hooks")
    }

    private var settingsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    }

    private var scriptPath: String {
        (hooksDir as NSString).appendingPathComponent("\(Self.scriptName).py")
    }

    private var commandPath: String {
        "~/.claude/hooks/\(Self.scriptName).py"
    }

    // Event list — install both notification events and silent tracking events so
    // the active-session list can track real live terminals instead of guessing
    // from transcript mtimes alone.
    private func eventNames() -> [String] {
        [
            "UserPromptSubmit",   // silent tracking — prompt sent
            "PreToolUse",         // silent tracking — tool starting
            "PostToolUse",        // silent tracking — tool finished
            "PostToolUseFailure", // silent tracking — tool failed/interrupted
            "SessionStart",       // new session
            "SessionEnd",         // silent tracking — session closed
            "Notification",       // Claude is waiting for input
            "Stop",               // task done
            "SubagentStart",      // silent tracking — subagent starting
            "SubagentStop",       // subagent done
            "StopFailure",        // API error / billing / rate limit (v2.1.78+)
            "PermissionRequest",  // bidirectional approval
            "PreCompact",         // silent tracking
            "PostCompact",        // silent tracking
        ]
    }

    // MARK: - HookInstalling

    var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: scriptPath) else { return false }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any] else {
            return false
        }
        for (_, value) in hooks {
            guard let matchers = value as? [[String: Any]] else { continue }
            for matcher in matchers {
                guard let inner = matcher["hooks"] as? [[String: Any]] else { continue }
                for h in inner {
                    if let cmd = h["command"] as? String, cmd.contains(Self.managedMarker) {
                        return true
                    }
                }
            }
        }
        return false
    }

    func install() async throws -> HookInstallResult {
        guard HookInstallerUtils.python3Available() else {
            return .python3Missing
        }

        let snapshot = FileSnapshot.capture(at: settingsPath)

        do {
            let fm = FileManager.default
            var root: [String: Any]
            if fm.fileExists(atPath: settingsPath) {
                let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw HookError.jsonParseError
                }
                root = obj
            } else {
                let parent = (settingsPath as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                root = [:]
            }

            var hooksDict = root["hooks"] as? [String: Any] ?? [:]

            // Strip managed hooks from ALL events first (even ones we no longer register,
            // so an upgrade from an old version cleans up stale entries).
            for key in hooksDict.keys {
                if let matchers = hooksDict[key] as? [[String: Any]] {
                    let pruned = pruneManagedHooks(from: matchers)
                    if pruned.isEmpty {
                        hooksDict.removeValue(forKey: key)
                    } else {
                        hooksDict[key] = pruned
                    }
                }
            }

            // Add our hook to the event list we care about
            let events = eventNames()
            for event in events {
                var matchers = hooksDict[event] as? [[String: Any]] ?? []
                let entry: [String: Any] = [
                    "hooks": [["type": "command", "command": commandPath]]
                ]
                matchers.append(entry)
                hooksDict[event] = matchers
            }

            root["hooks"] = hooksDict

            let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)

            try HookInstallerUtils.installScript(bundleResourceName: Self.scriptName, destinationDir: hooksDir)
        } catch {
            try? snapshot.restore()
            throw error
        }
        return .success
    }

    func uninstall() async throws -> HookInstallResult {
        let snapshot = FileSnapshot.capture(at: settingsPath)

        do {
            let fm = FileManager.default
            guard fm.fileExists(atPath: settingsPath) else {
                HookInstallerUtils.removeScript(at: scriptPath)
                return .success
            }

            let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HookError.jsonParseError
            }

            if var hooksDict = root["hooks"] as? [String: Any] {
                for key in hooksDict.keys {
                    if let matchers = hooksDict[key] as? [[String: Any]] {
                        hooksDict[key] = pruneManagedHooks(from: matchers)
                    }
                }
                for key in hooksDict.keys {
                    if let arr = hooksDict[key] as? [[String: Any]], arr.isEmpty {
                        hooksDict.removeValue(forKey: key)
                    }
                }
                if hooksDict.isEmpty {
                    root.removeValue(forKey: "hooks")
                } else {
                    root["hooks"] = hooksDict
                }
            }

            let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            HookInstallerUtils.removeScript(at: scriptPath)
        } catch {
            try? snapshot.restore()
            throw error
        }
        return .success
    }

    // MARK: - Private

    private func pruneManagedHooks(from matchers: [[String: Any]]) -> [[String: Any]] {
        matchers.filter { matcher in
            guard let inner = matcher["hooks"] as? [[String: Any]] else { return true }
            return !inner.contains { h in
                (h["command"] as? String)?.contains(Self.managedMarker) == true
            }
        }
    }
}
