import Foundation
import ClaudeStatisticsKit

/// Bridge between HookCLI's switch and the plugin's
/// `ProviderHookNormalizing` capability. Loaded once per CLI
/// invocation: the plugin registry is rebuilt from
/// `<app>/Contents/PlugIns/` because hook CLI mode skips the regular
/// AppState bootstrap.
///
/// Builtin Claude / Codex hooks stay outside this path while their
/// plugins haven't been extracted yet — HookRunner's switch dispatches
/// them directly. Anything else (Gemini today, third-party tomorrow)
/// arrives here through the `default` arm.
@MainActor
enum HookPluginRouter {
    private static var cachedRegistry: PluginRegistry?

    private static func registry() -> PluginRegistry {
        if let r = cachedRegistry { return r }
        let r = PluginRegistry()
        // PlugIns dir lives at .app/Contents/PlugIns/ for installed
        // builds and at the equivalent path inside the test host
        // / debug build product. Bundle.main.builtInPlugInsURL wraps
        // both cases.
        if let url = Bundle.main.builtInPlugInsURL {
            _ = PluginLoader.loadAll(from: url, into: r, sourceKind: .bundled)
        }
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
