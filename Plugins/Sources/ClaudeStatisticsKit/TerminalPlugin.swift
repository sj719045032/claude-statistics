import Foundation

/// A plugin that contributes a terminal-emulator adapter (focus return
/// + launching new sessions). Concrete plugins refine `Plugin` with
/// the host-facing factory methods stage 4 will fully flesh out
/// (`makeFocusStrategy`, `makeLauncher`, `makeSetupWizard`,
/// `makeContextProbe`).
///
/// Stage 3 introduces the minimal protocol surface — `descriptor` plus
/// `detectInstalled()` — so the host's `PluginRegistry` and any
/// third-party plugin can interoperate at the metadata level. The
/// three behaviour factory methods land as their corresponding
/// strategy / launcher / wizard protocols migrate into this SDK.
public protocol TerminalPlugin: Plugin {
    var descriptor: TerminalDescriptor { get }
    /// Quick best-effort check. Used by the host's Auto-launch picker
    /// and the Settings → Terminal readiness view to skip plugins
    /// whose backing app isn't installed. Default: returns `true`
    /// (the host falls back to existing capability-level checks).
    func detectInstalled() -> Bool
}

extension TerminalPlugin {
    public func detectInstalled() -> Bool { true }
}
