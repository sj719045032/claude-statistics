import ClaudeStatisticsKit
import Foundation

@MainActor
enum PluginRegistryBootstrap {
    static let hostPluginFactories: [String: () -> any Plugin] = [
        ClaudePluginDogfood.manifest.id: { ClaudePluginDogfood() },
        AppleTerminalPlugin.manifest.id: { AppleTerminalPlugin() }
    ]

    static func registerHostPlugins(into registry: PluginRegistry) {
        let plugins: [any Plugin] = hostPluginFactories
            .sorted { $0.key < $1.key }
            .map { $0.value() }

        for plugin in plugins {
            let manifest = type(of: plugin).manifest
            if PluginTrustGate.isDisabled(manifest.id) {
                registry.recordDisabled(manifest: manifest, source: .host)
                continue
            }
            do {
                try registry.register(plugin)
            } catch {
                DiagnosticLogger.shared.warning(
                    "PluginRegistry host register failed for \(type(of: plugin)): \(error)"
                )
            }
        }
    }

    static func loadBundledPlugins(into registry: PluginRegistry) {
        guard let pluginsDir = Bundle.main.builtInPlugInsURL else { return }
        let report = PluginLoader.loadAll(
            from: pluginsDir,
            into: registry,
            trustEvaluator: { _, _ in true },
            disabledChecker: PluginTrustGate.isDisabled,
            sourceKind: .bundled
        )
        log(report: report, label: "bundled")
    }

    static func loadUserPlugins(into registry: PluginRegistry) {
        let report = PluginLoader.loadAll(
            from: PluginLoader.defaultDirectory,
            into: registry,
            trustEvaluator: PluginTrustGate.evaluate,
            disabledChecker: PluginTrustGate.isDisabled,
            sourceKind: .user
        )
        log(
            report: report,
            label: "user",
            suffix: " pending=\(PluginTrustGate.snapshotPending().count)"
        )
    }

    private static func log(
        report: PluginLoader.Report,
        label: String,
        suffix: String = ""
    ) {
        DiagnosticLogger.shared.info(
            "PluginLoader (\(label)): loaded=\(report.loaded.count) skipped=\(report.skipped.count)\(suffix)"
        )
        for skip in report.skipped {
            DiagnosticLogger.shared.warning(
                "PluginLoader skipped \(skip.url.lastPathComponent): \(skip.reason)"
            )
        }
    }
}
