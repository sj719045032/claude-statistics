import Foundation
import ClaudeStatisticsKit

/// Bridge between HookCLI's switch and the plugin's
/// `ProviderHookNormalizing` capability. Loaded once per CLI
/// invocation: the plugin registry is rebuilt from
/// `<app>/Contents/PlugIns/` plus the per-user plugin directory because
/// hook CLI mode skips the regular AppState bootstrap.
///
/// Claude still has a host-owned normalizer and is dispatched directly by
/// HookRunner. Extracted providers such as Codex / Gemini, plus third-party
/// plugins, arrive here through the `default` arm.
@MainActor
enum HookPluginRouter {
    private static var cachedRegistry: PluginRegistry?

    private static func registry() -> PluginRegistry {
        if let r = cachedRegistry { return r }
        let r = PluginRegistry()
        PluginRegistryBootstrap.loadBundledPlugins(into: r)
        PluginRegistryBootstrap.loadUserPlugins(into: r)
        cachedRegistry = r
        return r
    }

    static func action(
        for providerId: String,
        payload: [String: Any],
        helper: any HookHelperContext
    ) -> HookAction? {
        let plugins = registry().providers.values
        guard let normalizer = plugins
            .compactMap({ $0 as? any ProviderHookNormalizing })
            .first(where: { $0.hookProviderId == providerId }),
              let envelope = normalizer.normalize(payload: payload, helper: helper)
        else {
            DiagnosticLogger.shared.warning(
                "HookPluginRouter no normalizer provider=\(providerId) loadedProviders=\(plugins.map { type(of: $0).manifest.id }.sorted().joined(separator: ","))"
            )
            return nil
        }

        let printDecision: ((String?) -> Void)?
        switch envelope.permissionDecisionStyle {
        case .claude:
            printDecision = { decision in printClaudePermissionDecision(decision) }
        case .codex:
            printDecision = { decision in printCodexPermissionDecision(decision) }
        case nil:
            printDecision = nil
        }

        return HookAction(
            message: envelope.message,
            expectsResponse: envelope.expectsResponse,
            responseTimeoutSeconds: envelope.responseTimeoutSeconds,
            printDecision: printDecision
        )
    }
}
