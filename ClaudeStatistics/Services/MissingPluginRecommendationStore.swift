import AppKit
import Foundation
import ClaudeStatisticsKit

struct MissingPluginRecommendation: Equatable, Identifiable {
    enum Action: Equatable {
        case install
        case enable
    }

    let pluginID: String
    let bundleID: String
    let appName: String
    let provider: ProviderKind
    let action: Action
    let lastSeenAt: Date
    let count: Int

    var id: String { "\(provider.rawValue):\(pluginID)" }
}

final class MissingPluginRecommendationStore {
    static let shared = MissingPluginRecommendationStore()

    static let didChange = Notification.Name("MissingPluginRecommendationStore.didChange")

    private struct CatalogTerminal: Equatable {
        let bundleID: String
        let pluginID: String
        let appName: String
    }

    private struct Signal: Codable, Equatable {
        let bundleID: String
        let pluginID: String
        let appName: String
        let providerID: String
        var lastSeenAt: Date
        var count: Int
    }

    private let key = "missingPluginRecommendations.v1"
    private let maxAge: TimeInterval = 24 * 60 * 60

    private init() {}

    func recordUnclaimedHost(bundleID: String, provider: ProviderKind, at date: Date = Date()) {
        guard let host = marketplaceTerminal(bundleID: bundleID) else { return }
        let id = signalID(providerID: provider.rawValue, pluginID: host.pluginID)
        var signals = loadSignals()
        var signal = signals[id] ?? Signal(
            bundleID: host.bundleID,
            pluginID: host.pluginID,
            appName: host.appName,
            providerID: provider.rawValue,
            lastSeenAt: date,
            count: 0
        )
        signal.lastSeenAt = date
        signal.count += 1
        signals[id] = signal
        save(signals)
        DiagnosticLogger.shared.info(
            "Missing plugin recommendation signal provider=\(provider.rawValue) plugin=\(host.pluginID) bundle=\(bundleID) count=\(signal.count)"
        )
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    @MainActor
    func recommendation(for provider: ProviderKind, pluginRegistry: PluginRegistry, now: Date = Date()) -> MissingPluginRecommendation? {
        let signals = loadSignals().values
            .filter { $0.providerID == provider.rawValue }
            .filter { now.timeIntervalSince($0.lastSeenAt) <= maxAge }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }

        for signal in signals {
            if pluginRegistry.terminalPlugin(id: signal.pluginID) != nil {
                continue
            }
            let isDisabled = pluginRegistry.disabledRecords().contains { $0.manifest.id == signal.pluginID }
            return MissingPluginRecommendation(
                pluginID: signal.pluginID,
                bundleID: signal.bundleID,
                appName: signal.appName,
                provider: provider,
                action: isDisabled ? .enable : .install,
                lastSeenAt: signal.lastSeenAt,
                count: signal.count
            )
        }

        return nil
    }

    private func signalID(providerID: String, pluginID: String) -> String {
        "\(providerID)|\(pluginID)"
    }

    private func marketplaceTerminal(bundleID: String) -> CatalogTerminal? {
        guard let normalizedBundleID = normalized(bundleID) else { return nil }
        guard let data = try? Data(contentsOf: PluginCatalog.defaultCacheURL),
              let index = try? PluginCatalog.decode(data),
              let entry = index.entries.first(where: {
                  normalized($0.id) == normalizedBundleID
                      && PluginCatalogCategory.canonicalize($0.category) == PluginCatalogCategory.terminal
              }) else {
            return nil
        }

        return CatalogTerminal(
            bundleID: normalizedBundleID,
            pluginID: entry.id,
            appName: appDisplayName(bundleID: normalizedBundleID) ?? entry.name
        )
    }

    private func appDisplayName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else {
            return nil
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func loadSignals() -> [String: Signal] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Signal].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func save(_ signals: [String: Signal]) {
        guard let data = try? JSONEncoder().encode(signals) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
