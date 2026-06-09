import Foundation

final class BackupService {
    static let shared = BackupService()
    private init() {}

    struct Manifest: Codable {
        let formatVersion: Int
        let appVersion: String
        let date: Date
        let sessionCount: Int
        let providers: [String: Int]
    }

    enum BackupError: LocalizedError {
        case noDatabase
        case invalidBackup
        case zipFailed
        case unzipFailed

        var errorDescription: String? {
            switch self {
            case .noDatabase: return "Database not found"
            case .invalidBackup: return "Invalid backup file"
            case .zipFailed: return "Failed to create backup archive"
            case .unzipFailed: return "Failed to extract backup archive"
            }
        }
    }

    private var dataDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ClaudeStatistics")
    }

    private var pluginStateDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Claude Statistics")
    }

    var databaseSize: Int64 {
        let dbPath = dataDir.appendingPathComponent("data.db").path
        let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath)
        return (attrs?[.size] as? Int64) ?? 0
    }

    // MARK: - Export

    func exportBackup(to url: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("csbackup-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let db = DatabaseService.shared
        let manifest = buildManifest()
        db.checkpoint()
        db.close()
        defer { db.open() }

        let dbSrc = dataDir.appendingPathComponent("data.db")
        guard fm.fileExists(atPath: dbSrc.path) else { throw BackupError.noDatabase }
        try fm.copyItem(at: dbSrc, to: tmp.appendingPathComponent("data.db"))

        let prefs = exportPreferences()
        try JSONSerialization.data(withJSONObject: prefs, options: [.prettyPrinted, .sortedKeys])
            .write(to: tmp.appendingPathComponent("preferences.json"))

        for name in ["trust.json", "disabled-plugins.json"] {
            let src = pluginStateDir.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: tmp.appendingPathComponent(name))
            }
        }

        let pluginsDir = pluginStateDir.appendingPathComponent("Plugins")
        if fm.fileExists(atPath: pluginsDir.path) {
            try fm.copyItem(at: pluginsDir, to: tmp.appendingPathComponent("Plugins"))
        }
        try JSONEncoder.iso8601Encoder.encode(manifest)
            .write(to: tmp.appendingPathComponent("manifest.json"))

        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--sequesterRsrc", tmp.path, url.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw BackupError.zipFailed }
    }

    // MARK: - Import

    func peekManifest(at url: URL) throws -> Manifest {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cspeek-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", url.path, tmp.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw BackupError.unzipFailed }

        let manifestURL = tmp.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else { throw BackupError.invalidBackup }
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder.iso8601Decoder.decode(Manifest.self, from: data)
    }

    func importBackup(from url: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("csimport-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", url.path, tmp.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw BackupError.unzipFailed }

        let dbSrc = tmp.appendingPathComponent("data.db")
        guard fm.fileExists(atPath: dbSrc.path) else { throw BackupError.invalidBackup }

        let db = DatabaseService.shared
        db.close()

        let dbDst = dataDir.appendingPathComponent("data.db")
        for ext in ["", "-shm", "-wal"] {
            let path = dbDst.path + ext
            if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        }
        try fm.copyItem(at: dbSrc, to: dbDst)

        let prefsURL = tmp.appendingPathComponent("preferences.json")
        if fm.fileExists(atPath: prefsURL.path),
           let data = try? Data(contentsOf: prefsURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            importPreferences(dict)
        }

        for name in ["trust.json", "disabled-plugins.json"] {
            let src = tmp.appendingPathComponent(name)
            let dst = pluginStateDir.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }

        let pluginsSrc = tmp.appendingPathComponent("Plugins")
        if fm.fileExists(atPath: pluginsSrc.path) {
            let pluginsDst = pluginStateDir.appendingPathComponent("Plugins")
            try? fm.createDirectory(at: pluginsDst, withIntermediateDirectories: true)
            let items = (try? fm.contentsOfDirectory(atPath: pluginsSrc.path)) ?? []
            for item in items where item.hasSuffix(".csplugin") {
                let src = pluginsSrc.appendingPathComponent(item)
                let dst = pluginsDst.appendingPathComponent(item)
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }

        db.open()
    }

    // MARK: - Preferences

    private static let preferenceKeys: [String] = [
        AppPreferences.autoRefreshEnabled,
        AppPreferences.refreshInterval,
        AppPreferences.customInterval,
        AppPreferences.appLanguage,
        AppPreferences.fontScale,
        AppPreferences.tabOrder,
        AppPreferences.notchSoundEnabled,
        AppPreferences.notchSoundName,
        AppPreferences.notchFocusSilenceEnabled,
        AppPreferences.verboseLogging,
    ]

    private static let preferenceKeyPrefixes = [
        "notch.",
        "globalHotKey",
        "menuBar.visible.",
        "preferredTerminal.",
    ]

    private func exportPreferences() -> [String: Any] {
        let defaults = UserDefaults.standard
        let all = defaults.dictionaryRepresentation()
        return all.filter { key, _ in
            Self.preferenceKeys.contains(key) ||
            Self.preferenceKeyPrefixes.contains(where: { key.hasPrefix($0) })
        }
    }

    private func importPreferences(_ dict: [String: Any]) {
        let defaults = UserDefaults.standard
        for (key, value) in dict {
            guard Self.preferenceKeys.contains(key) ||
                  Self.preferenceKeyPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            defaults.set(value, forKey: key)
        }
    }

    // MARK: - Manifest

    private func buildManifest() -> Manifest {
        let db = DatabaseService.shared
        let summary = db.backupProviderSummary()
        return Manifest(
            formatVersion: 1,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            date: Date(),
            sessionCount: summary.values.reduce(0, +),
            providers: summary
        )
    }
}

private extension JSONEncoder {
    static let iso8601Encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso8601Decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
