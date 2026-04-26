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
}

extension ProviderPlugin {
    public func makeProvider() -> (any BundledSessionProvider)? { nil }
}
