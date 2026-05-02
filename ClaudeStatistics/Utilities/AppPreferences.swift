import Foundation

/// Single source of truth for raw `UserDefaults` key strings used across the
/// app. Domain-specific preference namespaces (`NotchPreferences`,
/// `MenuBarPreferences`, `TerminalPreferences`, `GlobalHotKeyShortcut`, …)
/// already centralize their own keys; this enum collects everything else
/// that previously appeared as a string literal in two or more places.
///
/// Add a constant here whenever a preference key needs to be referenced
/// outside the file that primarily owns it. Avoid renaming an entry
/// without a migration — `UserDefaults` is keyed by string and renames
/// silently lose user-set values.
enum AppPreferences {
    // MARK: Sync / refresh

    /// Master switch for usage auto-refresh.
    static let autoRefreshEnabled = "autoRefreshEnabled"
    /// Auto-refresh interval in seconds. Default 300.
    static let refreshInterval = "refreshInterval"
    /// Whether the user typed a custom (non-preset) refresh interval.
    static let customInterval = "customInterval"

    // MARK: UI

    /// User-selected app language code (`"auto"`, `"en"`, `"zh-Hans"`).
    static let appLanguage = "appLanguage"
    /// Menu-bar / panel font scale multiplier. Default 1.0.
    static let fontScale = "fontScale"
    /// Sparkle update version the user explicitly dismissed.
    static let ignoredUpdateVersion = "ignoredUpdateVersion"
    /// Persisted ordering of the four panel tabs (encoded JSON of `[String]`).
    static let tabOrder = "tabOrder"

    // MARK: Notch

    /// Master switch for notch event sound.
    static let notchSoundEnabled = "notch.sound.enabled"
    /// Selected notch sound name (NSSound system sounds).
    static let notchSoundName = "notch.sound.name"
    /// Whether to silence notch sounds when the active app is in focus.
    static let notchFocusSilenceEnabled = "notch.focusSilence.enabled"

    // MARK: Diagnostic

    /// Verbose diagnostic logging toggle.
    static let verboseLogging = "diagnostic.verbose.enabled"

    // MARK: Provider usage backoff

    /// Claude usage API retry-after deadline (Date).
    static let claudeUsageRetryAfter = "usageAPIRetryAfter"
    /// Codex usage API retry-after deadline (Date).
    static let codexUsageRetryAfter = "codexUsageAPIRetryAfter"

    // MARK: Default registration

    /// Defaults registered on app launch via `UserDefaults.standard.register`.
    /// `register` only seeds values for keys the user has never set, so adding
    /// an entry here is safe to ship — existing user choices are preserved.
    static let registeredDefaults: [String: Any] = [
        autoRefreshEnabled: true,
        refreshInterval: 300.0
    ]
}
