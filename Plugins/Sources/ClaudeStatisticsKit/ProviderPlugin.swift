import Foundation

/// A plugin that contributes a vendor adapter for an AI coding CLI
/// (Claude / Codex / Gemini / Aider / …). Concrete plugins refine
/// `Plugin` with the host-facing factory methods stage 4 will fully
/// flesh out (`makeSessionDataProvider`, `makeUsageProvider`,
/// `makeAccountProvider`, `makeHookProvider`, `makeSessionLauncher`,
/// `makeViewContributor`).
///
/// Stage 3 introduces the minimal protocol surface — just the
/// `descriptor` — so the host's `PluginRegistry` and any third-party
/// plugin can interoperate at the metadata level. The five capability
/// factory methods land as the corresponding narrow protocols
/// (`SessionDataProvider` etc.) themselves migrate into this SDK.
public protocol ProviderPlugin: Plugin {
    var descriptor: ProviderDescriptor { get }
}
