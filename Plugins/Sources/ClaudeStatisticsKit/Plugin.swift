import Foundation

/// Shared base for every plugin contributed to Claude Statistics.
///
/// Concrete plugin protocols (`ProviderPlugin`, `TerminalPlugin`,
/// `ShareRolePlugin`, `ShareCardThemePlugin`) refine this with the
/// specific factory methods their kind requires. The host loader only
/// handles `any Plugin` directly when it walks `.csplugin` bundles —
/// after instantiation it casts to the kind-specific protocol based on
/// `Self.manifest.kind`.
///
/// Kept `AnyObject` so the loader can hold a single live instance per
/// plugin id and so `init()` (required for `NSClassFromString`-style
/// instantiation) is well-defined.
public protocol Plugin: AnyObject {
    /// Static manifest. The loader reads this before deciding whether
    /// to instantiate (version compatibility + permission prompt).
    static var manifest: PluginManifest { get }

    /// Default constructor invoked by the host loader. Plugins should
    /// keep this lightweight — heavy work belongs in the kind-specific
    /// `make…()` factory methods (`makeSessionDataProvider`,
    /// `makeFocusStrategy`, etc.) called lazily by the host.
    init()
}
