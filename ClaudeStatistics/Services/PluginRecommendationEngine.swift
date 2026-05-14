import AppKit
import Foundation
import ClaudeStatisticsKit

enum PluginRecommendationSource: String, Equatable {
    case onboardingScan
    case missingRuntimeHost
    case disabledPlugin
    case installedApp
}

struct PluginRecommendation: Identifiable, Equatable {
    enum Action: Equatable {
        case install
        case enable
    }

    let pluginID: String
    let displayName: String
    let appName: String
    let detail: String
    let source: PluginRecommendationSource
    let action: Action
    let catalogEntry: PluginCatalogEntry?

    var id: String { "\(source.rawValue):\(pluginID)" }
}

struct PluginRecommendationScan: Equatable {
    let detectedApps: [String]
    let recommendations: [PluginRecommendation]
    let catalogKind: PluginCatalog.Outcome.Kind?
}

@MainActor
enum PluginRecommendationEngine {
    static func scan(
        provider: ProviderKind,
        pluginRegistry: PluginRegistry,
        catalogURL: URL? = nil
    ) async -> PluginRecommendationScan {
        let catalog = PluginCatalog(remoteURL: catalogURL ?? PluginCatalog.defaultRemoteURL)
        let outcome = try? await catalog.fetch()
        let entries = outcome?.index.entries ?? cachedCatalogEntries()
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let installedIDs = Set(pluginRegistry.loadedManifests().map(\.id))
        let disabledRecords = pluginRegistry.disabledRecords()
        let disabledIDs = Set(disabledRecords.map(\.manifest.id))

        var detectedApps: [String] = []
        var recommendationsByID: [String: PluginRecommendation] = [:]

        if let runtime = MissingPluginRecommendationStore.shared.recommendation(
            for: provider,
            pluginRegistry: pluginRegistry
        ), runtime.action != .enable {
            let entry = entriesByID[runtime.pluginID]
            recommendationsByID[runtime.pluginID] = PluginRecommendation(
                pluginID: runtime.pluginID,
                displayName: entry?.name ?? runtime.appName,
                appName: runtime.appName,
                detail: String(
                    format: NSLocalizedString("onboarding.recommendation.runtime %@", comment: ""),
                    runtime.appName
                ),
                source: .missingRuntimeHost,
                action: runtime.action == .enable ? .enable : .install,
                catalogEntry: entry
            )
            detectedApps.append(runtime.appName)
        }

        for entry in entries where PluginCatalogCategory.canonicalize(entry.category) == PluginCatalogCategory.terminal {
            let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !installedIDs.contains(entry.id), !disabledIDs.contains(entry.id) else { continue }
            guard let appURL = installedApplicationURL(bundleID: id) else { continue }
            let appName = appDisplayName(at: appURL) ?? entry.name
            detectedApps.append(appName)
            recommendationsByID[entry.id] = PluginRecommendation(
                pluginID: entry.id,
                displayName: entry.name,
                appName: appName,
                detail: String(
                    format: NSLocalizedString("onboarding.recommendation.installedApp %@", comment: ""),
                    appName
                ),
                source: .installedApp,
                action: .install,
                catalogEntry: entry
            )
        }

        let recommendations = Array(recommendationsByID.values)
            .sorted { lhs, rhs in
                if priority(lhs.source) != priority(rhs.source) {
                    return priority(lhs.source) < priority(rhs.source)
                }
                return lhs.displayName < rhs.displayName
            }

        return PluginRecommendationScan(
            detectedApps: Array(Set(detectedApps)).sorted(),
            recommendations: recommendations,
            catalogKind: outcome?.kind
        )
    }

    private static func cachedCatalogEntries() -> [PluginCatalogEntry] {
        guard let data = try? Data(contentsOf: PluginCatalog.defaultCacheURL),
              let index = try? PluginCatalog.decode(data) else {
            return []
        }
        return index.entries
    }

    private static func appDisplayName(at url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
    }

    private static func installedApplicationURL(bundleID: String) -> URL? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              url.pathExtension == "app",
              !isMountedVolumeApplication(url),
              let bundle = Bundle(url: url),
              normalized(bundle.bundleIdentifier) == normalized(bundleID) else {
            return nil
        }
        return url
    }

    private static func isMountedVolumeApplication(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix("/Volumes/")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func priority(_ source: PluginRecommendationSource) -> Int {
        switch source {
        case .missingRuntimeHost: return 0
        case .disabledPlugin:     return 1
        case .installedApp:       return 2
        case .onboardingScan:     return 3
        }
    }
}
