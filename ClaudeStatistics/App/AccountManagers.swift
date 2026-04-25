import Foundation

/// Owns the per-provider account managers as a single value-typed bundle.
/// Pulled out of `AppState` so the top-level state object isn't responsible
/// for the four manager instances and their per-kind reload routing.
@MainActor
struct AccountManagers {
    let claude = ClaudeAccountManager()
    let independentClaude = IndependentClaudeAccountManager()
    let codex = CodexAccountManager()
    let gemini = GeminiAccountManager()

    /// Reload the manager(s) backing the given provider after credentials
    /// change (login, logout, account switch). Claude has two managers
    /// (managed + independent) and reloads both; the others have one.
    func reload(for kind: ProviderKind) {
        switch kind {
        case .claude:
            claude.load()
            independentClaude.load()
        case .codex:
            codex.load()
        case .gemini:
            gemini.load()
        }
    }
}
