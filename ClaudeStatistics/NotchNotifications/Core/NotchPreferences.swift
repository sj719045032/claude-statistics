import Foundation
import ClaudeStatisticsKit

/// Accessors for the per-provider notch master switch, plus one-time migration
/// from the legacy single `notch.enabled` key. No provider-specific logic lives
/// here — capability (which events a provider emits, whether an installer
/// exists) is declared on each `SessionProvider`.
enum NotchPreferences {
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
        isEnabled(defaultsKey: kind.descriptor.notchEnabledDefaultsKey)
    }

    /// Plugin-aware variant: any descriptor (builtin or
    /// plugin-contributed) carries its own `notchEnabledDefaultsKey`,
    /// so we read the descriptor's key directly instead of
    /// reconstructing it from id. Used by `anyProviderEnabled` to
    /// honour third-party `ProviderPlugin` notch toggles.
    static func isEnabled(descriptor: ProviderDescriptor) -> Bool {
        isEnabled(defaultsKey: descriptor.notchEnabledDefaultsKey)
    }

    private static func isEnabled(defaultsKey key: String) -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: key) == nil || d.bool(forKey: key)
    }

    /// Flips the master switch for a provider and posts `stateChangedNotification`
    /// so the AppDelegate can reconcile the island stack.
    static func setEnabled(_ enabled: Bool, for kind: ProviderKind) {
        UserDefaults.standard.set(enabled, forKey: kind.descriptor.notchEnabledDefaultsKey)
        NotificationCenter.default.post(name: stateChangedNotification, object: nil)
    }

    /// True when at least one provider's master switch is on — drives whether
    /// the bridge, tracker, and notch window are alive at all. Honours
    /// plugin-contributed descriptors via the shared `PluginRegistry`.
    @MainActor
    static var anyProviderEnabled: Bool {
        let plugins = ProviderRegistry.currentSharedPluginRegistry()
        let descriptors = ProviderRegistry.allKnownDescriptors(plugins: plugins)
        return descriptors.contains { isEnabled(descriptor: $0) }
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
        for kind in ProviderKind.allBuiltins {
            let key = kind.descriptor.notchEnabledDefaultsKey
            if d.object(forKey: key) == nil {
                d.set(legacyOn, forKey: key)
            }
        }
        d.removeObject(forKey: legacyKey)
    }
}

// NotchEventKind lives in ClaudeStatisticsKit.
