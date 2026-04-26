import Foundation
import ClaudeStatisticsKit

/// Owns the per-provider account managers. Pulled out of `AppState` so
/// the top-level state object isn't responsible for the four manager
/// instances and their per-kind reload routing.
///
/// The hard-typed properties (`claude` / `independentClaude` / `codex`
/// / `gemini`) stay for now because Settings accessories reach into
/// them directly. The `reload(for:)` path, however, is plugin-aware:
/// reload functions are stored in a `descriptor.id`-keyed dictionary
/// so when Codex / Gemini move to `.csplugin` bundles they can register
/// their own load hook via `registerReloader(for:_:)` without any
/// switch in this file.
@MainActor
final class AccountManagers {
    let claude = ClaudeAccountManager()
    let independentClaude = IndependentClaudeAccountManager()
    let codex = CodexAccountManager()
    let gemini = GeminiAccountManager()

    /// Per-descriptor.id reload function. Builtins seed three entries
    /// here at init time; third-party `ProviderPlugin`s register/
    /// unregister their own through the public API below as they
    /// hot-load and disable.
    private var reloaders: [String: () -> Void] = [:]

    init() {
        // Seed builtins so the existing `accounts.reload(for: kind)`
        // call sites keep working before any plugin wires its own.
        // Each closure captures `self` weakly to avoid a retain cycle
        // — `AccountManagers` outlives the reloader anyway since it's
        // owned by `AppState`.
        reloaders[ProviderDescriptor.claude.id] = { [weak self] in
            self?.claude.load()
            self?.independentClaude.load()
        }
        reloaders[ProviderDescriptor.codex.id] = { [weak self] in
            self?.codex.load()
        }
        reloaders[ProviderDescriptor.gemini.id] = { [weak self] in
            self?.gemini.load()
        }
    }

    /// Plugin-facing API: a `ProviderPlugin` whose adapter owns its
    /// own credential file calls this on hot-load so its descriptor
    /// id participates in `reload(for:)`. Idempotent — re-registering
    /// the same id replaces the closure.
    func registerReloader(for descriptorID: String, _ reloader: @escaping () -> Void) {
        reloaders[descriptorID] = reloader
    }

    func unregisterReloader(for descriptorID: String) {
        reloaders.removeValue(forKey: descriptorID)
    }

    /// Reload the manager(s) backing the given provider after credentials
    /// change (login, logout, account switch). Routes through
    /// `descriptor.id` so a plugin-contributed provider participates
    /// without a switch in this file.
    func reload(for kind: ProviderKind) {
        reload(forDescriptorID: kind.descriptor.id)
    }

    func reload(forDescriptorID descriptorID: String) {
        reloaders[descriptorID]?()
    }
}
