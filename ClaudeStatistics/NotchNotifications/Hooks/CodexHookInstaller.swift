import Foundation
import ClaudeStatisticsKit

struct CodexHookInstaller: HookInstalling {
    let providerId: String = ProviderKind.codex.rawValue

    private static let scriptName = "claude-stats-codex-hook"
    private static let managedMarkers = [
        "claude-stats-codex-hook",
        "claude-stats-hook",
        "codex-island-state.py",
        "claude-island-state.py",
        "--claude-stats-hook-provider",
    ]

    private let supportedHookEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "PostToolUseFailure",
        "Notification",
        "SubagentStart",
        "SubagentStop",
        "PreCompact",
        "PostCompact",
        "StopFailure",
        "Stop",
    ]

    private var codexDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    private var hooksDir: String {
        (codexDir as NSString).appendingPathComponent("hooks")
    }

    private var hooksPath: String {
        (codexDir as NSString).appendingPathComponent("hooks.json")
    }

    private var configPath: String {
        (codexDir as NSString).appendingPathComponent("config.toml")
    }

    private var scriptPath: String {
        (hooksDir as NSString).appendingPathComponent("\(Self.scriptName).py")
    }

    private var commandPath: String {
        HookInstallerUtils.currentHookCommand(providerId: providerId)
    }

    var isInstalled: Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: hooksPath)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = obj["hooks"] as? [String: Any] else {
            return false
        }
        return containsExactCommand(in: hooks, target: commandPath)
    }

    private func containsExactCommand(in hooks: [String: Any], target: String) -> Bool {
        for event in supportedHookEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            
            var found = false
            for entry in entries {
                guard let inner = entry["hooks"] as? [[String: Any]] else { continue }
                if inner.contains(where: { ($0["command"] as? String) == target }) {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    func install() async throws -> HookInstallResult {
        let snapshots = [
            FileSnapshot.capture(at: scriptPath),
            FileSnapshot.capture(at: hooksPath),
            FileSnapshot.capture(at: configPath),
        ]
        let hooksDirExisted = FileManager.default.fileExists(atPath: hooksDir)

        do {
            try updateHooks()
            try enableCodexHooksFeature()
            HookInstallerUtils.removeScript(at: scriptPath)
        } catch {
            for snapshot in snapshots {
                try? snapshot.restore()
            }
            if !hooksDirExisted {
                try? removeHooksDirIfEmpty()
            }
            throw error
        }

        return .success
    }

    func uninstall() async throws -> HookInstallResult {
        let snapshots = [
            FileSnapshot.capture(at: scriptPath),
            FileSnapshot.capture(at: hooksPath),
        ]

        do {
            HookInstallerUtils.removeScript(at: scriptPath)
            guard FileManager.default.fileExists(atPath: hooksPath) else {
                return .success
            }

            guard var root = try readHooksJSON(),
                  var hooks = root["hooks"] as? [String: Any] else {
                throw HookError.jsonParseError
            }

            pruneManagedHooks(from: &hooks)
            if hooks.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = hooks
            }

            try writeHooksJSON(root)
        } catch {
            for snapshot in snapshots {
                try? snapshot.restore()
            }
            throw error
        }

        return .success
    }

    private func updateHooks() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: codexDir, withIntermediateDirectories: true)

        var root = try readHooksJSON() ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        pruneManagedHooks(from: &hooks)

        for event in supportedHookEvents {
            let entry: [String: Any] = [
                "type": "command",
                "command": commandPath,
                "timeout": event == "PermissionRequest" ? 300 : 30,
            ]
            let group: [[String: Any]] = [
                ["hooks": [entry]]
            ]
            var entries = sanitizedEntries(from: hooks[event] as? [[String: Any]] ?? [])
            entries.append(contentsOf: group)
            hooks[event] = entries
        }

        root["hooks"] = hooks
        try writeHooksJSON(root)
    }

    private func enableCodexHooksFeature() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: codexDir, withIntermediateDirectories: true)

        let existing = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let updated = Self.updatedConfigContentEnablingCodexHooks(existing)
        guard updated != existing else { return }
        try updated.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    private static func updatedConfigContentEnablingCodexHooks(_ content: String) -> String {
        let normalized = content.isEmpty || content.hasSuffix("\n") ? content : "\(content)\n"

        guard let featuresRange = normalized.range(of: #"(?m)^\[features\]\s*$"#, options: .regularExpression) else {
            if normalized.isEmpty {
                return "[features]\ncodex_hooks = true\n"
            }
            return "\(normalized)\n[features]\ncodex_hooks = true\n"
        }

        let suffix = normalized[featuresRange.upperBound...]
        let nextSectionRange = suffix.range(of: #"(?m)^\["#, options: .regularExpression)
        let sectionEnd = nextSectionRange?.lowerBound ?? normalized.endIndex
        let featureBodyRange = featuresRange.upperBound..<sectionEnd
        let featureBody = String(normalized[featureBodyRange])

        if let codexHooksRange = normalized.range(
            of: #"(?m)^([ \t]*codex_hooks[ \t]*=[ \t]*)(true|false)([ \t]*(#.*)?)$"#,
            options: .regularExpression,
            range: featureBodyRange
        ) {
            let existingLine = String(normalized[codexHooksRange])
            let leadingWhitespace = String(existingLine.prefix { $0 == " " || $0 == "\t" })
            let comment = existingLine.firstIndex(of: "#").map { String(existingLine[$0...]).trimmingCharacters(in: .whitespaces) }
            var replacement = "\(leadingWhitespace)codex_hooks = true"
            if let comment, !comment.isEmpty {
                replacement.append(" \(comment)")
            }
            if existingLine == replacement {
                return content
            }

            var updated = normalized
            updated.replaceSubrange(codexHooksRange, with: replacement)
            return updated
        }

        var insertion = "codex_hooks = true\n"
        if !featureBody.isEmpty, !featureBody.hasPrefix("\n") {
            insertion = "\n\(insertion)"
        }

        var updated = normalized
        updated.insert(contentsOf: insertion, at: sectionEnd)
        return updated
    }

    private func readHooksJSON() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: hooksPath) else {
            return nil
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: hooksPath))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookError.jsonParseError
        }
        return root
    }

    private func writeHooksJSON(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        // Skip the write entirely when the target content hasn't changed. Codex
        // loads hooks.json during each session_init and has been observed to
        // silently disable hooks for that session when a rewrite lands in the
        // middle of startup. Content-diff means app relaunches are a no-op for
        // live codex sessions as long as the managed entries are unchanged.
        if let existing = try? Data(contentsOf: URL(fileURLWithPath: hooksPath)), existing == data {
            return
        }
        try data.write(to: URL(fileURLWithPath: hooksPath), options: .atomic)
    }

    private func pruneManagedHooks(from hooks: inout [String: Any]) {
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let sanitized = sanitizedEntries(from: entries)
            if sanitized.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = sanitized
            }
        }
    }

    private func sanitizedEntries(from entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry in
            guard let inner = entry["hooks"] as? [[String: Any]] else {
                return entry
            }

            let retained = inner.filter { hook in
                let command = hook["command"] as? String ?? ""
                return !Self.isManagedCommand(command)
            }
            guard !retained.isEmpty else {
                return nil
            }

            var sanitized = entry
            sanitized["hooks"] = retained
            return sanitized
        }
    }

    private static func isManagedCommand(_ command: String) -> Bool {
        managedMarkers.contains { command.contains($0) }
    }

    private func removeHooksDirIfEmpty() throws {
        let contents = try FileManager.default.contentsOfDirectory(atPath: hooksDir)
        if contents.isEmpty {
            try FileManager.default.removeItem(atPath: hooksDir)
        }
    }
}

enum NotchHookSync {
    /// Collected from each provider's own declaration — no central list to
    /// keep in sync. A provider without a `notchHookInstaller` simply sits out.
    /// `plugins` filters out provider plugins the user has disabled so
    /// their hook installers don't keep mounting on every notch
    /// reconciliation.
    @MainActor
    static func installers(plugins: PluginRegistry?) -> [any HookInstalling] {
        ProviderRegistry.availableProviders(plugins: plugins).compactMap { kind in
            ProviderRegistry.provider(for: kind).notchHookInstaller
        }
    }

    /// Install or uninstall each provider's hooks based on its own master switch.
    @MainActor
    @discardableResult
    static func syncCurrent(plugins: PluginRegistry? = nil) async throws -> HookInstallResult {
        var sawConfirmationDenied = false

        for installer in installers(plugins: plugins) {
            // Builtin installers always have a kind that maps back to the
            // legacy enum; default to .claude for the impossible no-match
            // path so the loop stays total.
            let kind = ProviderKind(rawValue: installer.providerId) ?? .claude
            let enabled = NotchPreferences.isEnabled(kind)
            let result = enabled
                ? try await installer.install()
                : try await installer.uninstall()

            switch result {
            case .success:
                continue
            case .confirmationDenied:
                sawConfirmationDenied = true
            case .failure(let error):
                throw error
            }
        }

        if sawConfirmationDenied { return .confirmationDenied }
        return .success
    }
}
