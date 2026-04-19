import Foundation

enum ClaudeAccountMode: String {
    /// App shares credentials with the `claude` CLI via the system keychain.
    /// Provides multi-account switching but may prompt for keychain ACL on app upgrade.
    case sync
    /// App runs its own OAuth flow and stores credentials in a file.
    /// Single account, zero keychain prompts.
    case independent
}

/// Central source of truth for which credential pathway Claude is using.
/// Observers react to `.claudeAccountModeChanged` to refresh UI and invalidate caches.
final class ClaudeAccountModeController {
    static let shared = ClaudeAccountModeController()

    private static let defaultsKey = "claudeAccountSyncMode"

    private init() {}

    /// First-launch default: Independent for everyone.
    /// Users who previously relied on the CLI-synced accounts can opt back
    /// into Sync from the Source dropdown in Settings.
    static func resolveInitialMode() -> ClaudeAccountMode {
        .independent
    }

    var mode: ClaudeAccountMode {
        if let stored = UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool {
            return stored ? .sync : .independent
        }
        return Self.resolveInitialMode()
    }

    func setMode(_ newValue: ClaudeAccountMode) {
        let previous = mode
        guard previous != newValue else { return }
        UserDefaults.standard.set(newValue == .sync, forKey: Self.defaultsKey)
        // Any cached token belongs to the old mode — purge so downstream reads
        // go through the new mode's credential source.
        CredentialService.shared.invalidate()
        NotificationCenter.default.post(
            name: .claudeAccountModeChanged,
            object: nil,
            userInfo: ["mode": newValue.rawValue]
        )
    }

    /// Persists the resolved default on first launch so subsequent reads don't flip on us.
    func persistInitialDefaultIfNeeded() {
        guard UserDefaults.standard.object(forKey: Self.defaultsKey) == nil else { return }
        let resolved = Self.resolveInitialMode()
        UserDefaults.standard.set(resolved == .sync, forKey: Self.defaultsKey)
    }
}

extension Notification.Name {
    static let claudeAccountModeChanged = Notification.Name("ClaudeAccountModeChanged")
}
