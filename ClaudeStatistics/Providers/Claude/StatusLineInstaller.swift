import Foundation
import ClaudeStatisticsKit

/// Manages installation of the Claude Statistics-integrated status line script
struct StatusLineInstaller {
    private static var managedRoot: String { AppRuntimePaths.rootDirectory }
    private static var managedBinDirectory: String { AppRuntimePaths.binDirectory }
    static var scriptPath: String { (managedBinDirectory as NSString).appendingPathComponent("claude-stats-statusline") }
    static var backupPath: String { (managedBinDirectory as NSString).appendingPathComponent("claude-stats-statusline.bak") }
    private static let legacyScriptPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusline-command.sh")
    private static let legacyBackupPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusline-command.sh.bak")
    static let marker = "# Claude Statistics Integration v3"
    private static let markerPrefix = "# Claude Statistics Integration"
    static let settingsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    static var settingsBackupPath: String { (managedRoot as NSString).appendingPathComponent("statusline-settings.bak.json") }
    private static let legacySettingsBackupPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusline-settings.bak.json")
    /// Status line config in `~/.claude/settings.json` only allows ONE
    /// command, so debug and release can't coexist there. Whichever build
    /// last ran `install()` wins — and its bash script reads from its own
    /// per-build root (`AppRuntimePaths.rootDirectory`). Path is templated
    /// into the script at install time, not hardcoded.
    private static var expectedCommand: String { "bash \(scriptPath)" }
    private static let legacyExpectedCommand = "bash ~/.claude/statusline-command.sh"

    /// Check if our integrated script is currently installed and settings.json is synced
    static var isInstalled: Bool {
        if scriptContainsMarker(at: scriptPath), isSettingsSynced(with: expectedCommands) {
            return true
        }

        // Treat the old ~/.claude install as installed so app startup can migrate it.
        return scriptContainsMarker(at: legacyScriptPath) && isSettingsSynced(with: legacyExpectedCommands)
    }

    /// Check if settings.json statusLine points to our script
    private static func isSettingsSynced(with commands: Set<String>) -> Bool {
        guard let settings = readSettings(),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else {
            return false
        }
        return commands.contains(command)
    }

    /// Check if a backup exists
    static var hasBackup: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: backupPath) || fm.fileExists(atPath: legacyBackupPath)
    }

    /// Install the integrated status line script
    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: managedBinDirectory, withIntermediateDirectories: true)

        try backupScriptIfNeeded(at: scriptPath, to: backupPath)

        // Write new script
        try generatedScript().write(toFile: scriptPath, atomically: true, encoding: .utf8)

        // Make executable
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

        try removeLegacyManagedScriptIfNeeded()

        // Sync settings.json to point statusLine to our script
        try syncSettingsOnInstall()
    }

    /// Restore the backup script
    static func restore() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: backupPath) {
            try restoreBackup(from: backupPath, to: scriptPath)
        } else if fm.fileExists(atPath: legacyBackupPath) {
            if scriptContainsMarker(at: scriptPath) {
                try? fm.removeItem(atPath: scriptPath)
            }
            try restoreBackup(from: legacyBackupPath, to: legacyScriptPath)
        } else {
            throw StatusLineError.noBackup
        }

        // Restore original statusLine config in settings.json
        try syncSettingsOnRestore()
    }

    enum StatusLineError: LocalizedError {
        case noBackup
        var errorDescription: String? { "No backup file found" }
    }

    private static var expectedCommands: Set<String> {
        [expectedCommand, "bash \(scriptPath)"]
    }

    private static var legacyExpectedCommands: Set<String> {
        [legacyExpectedCommand, "bash \(legacyScriptPath)"]
    }

    private static func scriptContainsMarker(at path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return content.contains(markerPrefix)
    }

    private static func backupScriptIfNeeded(at path: String, to backupPath: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }

        let current = try String(contentsOfFile: path, encoding: .utf8)
        guard !current.contains(markerPrefix) else { return }

        if fm.fileExists(atPath: backupPath) {
            try fm.removeItem(atPath: backupPath)
        }
        try fm.copyItem(atPath: path, toPath: backupPath)
    }

    private static func removeLegacyManagedScriptIfNeeded() throws {
        let fm = FileManager.default
        guard scriptContainsMarker(at: legacyScriptPath) else { return }
        try fm.removeItem(atPath: legacyScriptPath)
    }

    private static func restoreBackup(from backupPath: String, to destinationPath: String) throws {
        let fm = FileManager.default
        let parentDirectory = (destinationPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parentDirectory, withIntermediateDirectories: true)

        if fm.fileExists(atPath: destinationPath) {
            try fm.removeItem(atPath: destinationPath)
        }
        try fm.copyItem(atPath: backupPath, toPath: destinationPath)
        try fm.removeItem(atPath: backupPath)
    }

    // MARK: - Settings.json sync

    private static func readSettings() -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    private static func syncSettingsOnInstall() throws {
        var settings = readSettings() ?? [:]
        let fm = FileManager.default
        try fm.createDirectory(atPath: managedRoot, withIntermediateDirectories: true)

        // Backup current statusLine config on first install only
        if !fm.fileExists(atPath: settingsBackupPath),
           !fm.fileExists(atPath: legacySettingsBackupPath),
           let current = settings["statusLine"] {
            let backupData = try JSONSerialization.data(withJSONObject: current, options: .prettyPrinted)
            try backupData.write(to: URL(fileURLWithPath: settingsBackupPath), options: .atomic)
        }

        settings["statusLine"] = [
            "type": "command",
            "command": expectedCommand
        ]

        try writeSettings(settings)
    }

    private static func syncSettingsOnRestore() throws {
        var settings = readSettings() ?? [:]
        let fm = FileManager.default

        let backupPath = fm.fileExists(atPath: settingsBackupPath) ? settingsBackupPath : legacySettingsBackupPath
        if fm.fileExists(atPath: backupPath),
           let data = fm.contents(atPath: backupPath),
           let oldConfig = try? JSONSerialization.jsonObject(with: data) {
            settings["statusLine"] = oldConfig
            try fm.removeItem(atPath: backupPath)
        } else {
            settings.removeValue(forKey: "statusLine")
        }

        try writeSettings(settings)
    }
}
