import Foundation

struct GeminiStatusLineInstaller {
    static let settingsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/settings.json")
    static let backupPath = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/footer-settings.backup.json")

    static let presetItems: [String] = [
        "workspace",
        "git-branch",
        "sandbox",
        "model-name",
        "context-used",
        "quota",
        "token-count",
        "auth",
    ]

    private static let requiredItems = Set(presetItems)

    static var isInstalled: Bool {
        guard let footer = readFooterSettings(),
              let items = footer["items"] as? [String] else {
            return false
        }
        return requiredItems.isSubset(of: Set(items)) && (footer["showLabels"] as? Bool ?? false)
    }

    static var hasBackup: Bool {
        FileManager.default.fileExists(atPath: backupPath)
    }

    static func install() throws {
        var settings = try readSettings()
        let fm = FileManager.default

        if !fm.fileExists(atPath: backupPath),
           let ui = settings["ui"] as? [String: Any],
           let footer = ui["footer"] {
            let data = try JSONSerialization.data(withJSONObject: footer, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: backupPath), options: .atomic)
        }

        var ui = settings["ui"] as? [String: Any] ?? [:]
        ui["footer"] = [
            "items": presetItems,
            "showLabels": true,
        ]
        settings["ui"] = ui
        try writeSettings(settings)
    }

    static func restore() throws {
        let fm = FileManager.default
        var settings = try readSettings()
        var ui = settings["ui"] as? [String: Any] ?? [:]

        if fm.fileExists(atPath: backupPath),
           let data = fm.contents(atPath: backupPath),
           let footer = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            ui["footer"] = footer
            settings["ui"] = ui
            try writeSettings(settings)
            try fm.removeItem(atPath: backupPath)
            return
        }

        ui.removeValue(forKey: "footer")
        settings["ui"] = ui
        try writeSettings(settings)
    }

    private static func readSettings() throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath) else {
            throw GeminiStatusLineError.settingsNotFound
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiStatusLineError.invalidSettings
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

    private static func readFooterSettings() -> [String: Any]? {
        guard let settings = try? readSettings(),
              let ui = settings["ui"] as? [String: Any],
              let footer = ui["footer"] as? [String: Any] else {
            return nil
        }
        return footer
    }
}

enum GeminiStatusLineError: LocalizedError {
    case settingsNotFound
    case invalidSettings

    var errorDescription: String? {
        switch self {
        case .settingsNotFound:
            return "~/.gemini/settings.json not found. Run `gemini` at least once to initialize it."
        case .invalidSettings:
            return "~/.gemini/settings.json is not valid JSON."
        }
    }
}
