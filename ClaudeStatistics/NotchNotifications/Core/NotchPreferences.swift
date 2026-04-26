import Foundation
import ClaudeStatisticsKit

/// Accessors for the per-provider notch master switch, plus one-time migration
/// from the legacy single `notch.enabled` key. No provider-specific logic lives
/// here — capability (which events a provider emits, whether an installer
/// exists) is declared on each `SessionProvider`.
enum NotchPreferences {
    // Thin per-provider key aliases so `@AppStorage(NotchPreferences.claudeKey)`
    // in views reads cleanly. All delegate to the provider's own rawValue-based
    // key — no per-provider branching here.
    static var claudeKey: String { ProviderKind.claude.notchEnabledDefaultsKey }
    static var codexKey:  String { ProviderKind.codex.notchEnabledDefaultsKey }
    static var geminiKey: String { ProviderKind.gemini.notchEnabledDefaultsKey }
    static let screenSelectionKey = "notch.screen.selection"
    static let mainScreenSelection = "main"
    /// Master switch for keyboard-driven notch interaction: island hotkey
    /// shortcut-to-peek, arrow/enter/esc navigation inside cards. Off by
    /// default means hover + click only.
    static let keyboardControlsEnabledKey = "notch.keyboardControls.enabled"

    static var keyboardControlsEnabled: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: keyboardControlsEnabledKey) == nil || d.bool(forKey: keyboardControlsEnabledKey)
    }

    /// Expanded-row mode in IdlePeekCard: when on, each session row renders
    /// a vertical list of every active tool call (parent + subagent) instead
    /// of the single aggregated line. Off by default — row-dense layout.
    static let idlePeekDetailedRowsKey = "notch.idlePeek.detailedRows"

    static var idlePeekDetailedRows: Bool {
        UserDefaults.standard.bool(forKey: idlePeekDetailedRowsKey)
    }

    /// Reads the master switch for a provider. Default is on.
    static func isEnabled(_ kind: ProviderKind) -> Bool {
        let d = UserDefaults.standard
        let key = kind.notchEnabledDefaultsKey
        return d.object(forKey: key) == nil || d.bool(forKey: key)
    }

    /// Flips the master switch for a provider and posts `stateChangedNotification`
    /// so the AppDelegate can reconcile the island stack.
    static func setEnabled(_ enabled: Bool, for kind: ProviderKind) {
        UserDefaults.standard.set(enabled, forKey: kind.notchEnabledDefaultsKey)
        NotificationCenter.default.post(name: stateChangedNotification, object: nil)
    }

    /// True when at least one provider's master switch is on — drives whether
    /// the bridge, tracker, and notch window are alive at all.
    static var anyProviderEnabled: Bool {
        ProviderKind.allCases.contains(where: isEnabled)
    }

    static let stateChangedNotification = Notification.Name("notch.state.changed")
    static let screenChangedNotification = Notification.Name("notch.screen.changed")

    static var screenSelection: String {
        UserDefaults.standard.string(forKey: screenSelectionKey) ?? mainScreenSelection
    }

    static func setScreenSelection(_ selection: String) {
        UserDefaults.standard.set(selection, forKey: screenSelectionKey)
        NotificationCenter.default.post(name: screenChangedNotification, object: nil)
    }

    /// One-shot migration from the legacy `notch.enabled` key to per-provider
    /// keys. Called at app start. Idempotent.
    static func migrateLegacyIfNeeded() {
        let d = UserDefaults.standard
        let legacyKey = "notch.enabled"
        guard d.object(forKey: legacyKey) != nil else { return }
        let legacyOn = d.bool(forKey: legacyKey)
        // Only populate keys the user hasn't explicitly set, so a second
        // migration pass never clobbers a deliberate flip.
        for kind in ProviderKind.allCases {
            let key = kind.notchEnabledDefaultsKey
            if d.object(forKey: key) == nil {
                d.set(legacyOn, forKey: key)
            }
        }
        d.removeObject(forKey: legacyKey)
    }
}

// NotchEventKind lives in ClaudeStatisticsKit.
