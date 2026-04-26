import Foundation

/// Composition of every narrow protocol a Provider plugin can
/// implement. Equivalent to the host's historical `SessionProvider`
/// typealias, but defined in the SDK so plugins can return a fully
/// bundled adapter without depending on host types.
public typealias BundledSessionProvider =
    SessionDataProvider & UsageProvider & AccountProvider & HookProvider & SessionLauncher

/// A plugin that contributes a vendor adapter for an AI coding CLI
/// (Claude / Codex / Gemini / Aider / …).
///
/// `descriptor` is the only required member — it lets the host's
/// `PluginRegistry` and any third-party plugin interoperate at the
/// metadata level even before the plugin ships concrete behaviour.
///
/// Stage 4 wires the host's session/usage/account pipelines through
/// `makeProvider()`; until then the host keeps its legacy switch in
/// `ProviderRegistry.provider(for:)` and the wrappers expose the
/// existing singletons here so the factory is callable end-to-end.
public protocol ProviderPlugin: Plugin {
    var descriptor: ProviderDescriptor { get }

    /// Factory returning a fully-bundled adapter implementing every
    /// provider-side narrow protocol. `nil` means the plugin only
    /// contributes metadata (descriptor) and the host should rely on
    /// its legacy lookup for behaviour. Builtin dogfood plugins
    /// override this to return their `*.shared` singleton; third-party
    /// plugins typically construct a fresh instance on each call.
    func makeProvider() -> (any BundledSessionProvider)?

    /// Filters that hide rows from the active session list. Each
    /// plugin contributes its own set — e.g. Codex.app's ambient
    /// suggestion task is filtered by a `SyntheticPromptFilter`
    /// configured with the templated prompt prefix. The host runs
    /// every filter (its own + every plugin's) against incoming
    /// hooks and persisted runtime; any `false` hides the row.
    ///
    /// Default returns `[]`; plugins without filtering needs (most)
    /// don't override.
    func makeSessionFilters() -> [any SessionEventFilter]
}

extension ProviderPlugin {
    public func makeProvider() -> (any BundledSessionProvider)? { nil }
    public func makeSessionFilters() -> [any SessionEventFilter] { [] }
}
