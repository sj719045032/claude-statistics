import Foundation
import SwiftUI
import ClaudeStatisticsKit

/// Closed enum left over as a thin namespace for the three builtin
/// provider ids. All real provider behaviour now lives in
/// `ProviderDescriptor`; callers go through `kind.descriptor.<field>`.
/// Removing this enum entirely is a separate, larger surgery; this file
/// no longer hosts any per-case dispatch beyond the descriptor lookup.
enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex
    case gemini

    var id: String { rawValue }

    /// Builtin descriptor for this id. Plugin-contributed providers
    /// reach descriptors through `PluginRegistry` / `ProviderRegistry`,
    /// not through this property.
    var descriptor: ProviderDescriptor {
        switch self {
        case .claude: return .claude
        case .codex:  return .codex
        case .gemini: return .gemini
        }
    }
}

/// Convenience for kernel callers that want the legacy registry-free
/// resolve flavour (no plugin id required, just walks every builtin
/// provider's alias table). New code should prefer
/// `ClaudeStatisticsKit.CanonicalToolName.resolve(_:descriptors:)`
/// directly with the desired descriptor set.
enum HostCanonicalToolName {
    static func resolve(_ raw: String?) -> String {
        CanonicalToolName.resolve(raw, descriptors: ProviderKind.allCases.map(\.descriptor))
    }
}

/// Controls which providers' usage cells are shown in the status bar strip.
/// Defaults to all enabled so a fresh install shows every configured
/// provider; the user can hide individual providers from Settings.
///
/// The keying schema is anchored on `descriptor.id` (which equals
/// `ProviderKind.rawValue` for builtins). Plugin-contributed providers
/// supply their own descriptor.id and reuse the same `menuBar.visible.<id>`
/// path — no separate namespace, so existing users' preferences for
/// `claude/codex/gemini` carry over untouched.
enum MenuBarPreferences {
    static func key(forDescriptorID id: String) -> String {
        "menuBar.visible.\(id)"
    }

    static func key(for kind: ProviderKind) -> String {
        key(forDescriptorID: kind.rawValue)
    }

    /// Pre-seed UserDefaults so first-launch reads return `true` instead
    /// of `false` for the three builtin providers. Plugin descriptors
    /// register their own default at registration time via
    /// `registerDefault(forDescriptorID:)` below.
    static func register() {
        var defaults: [String: Any] = [:]
        for kind in ProviderKind.allCases {
            defaults[key(for: kind)] = true
        }
        UserDefaults.standard.register(defaults: defaults)
    }

    /// Called by `AppState` (or any plugin loader) once a `ProviderPlugin`
    /// becomes known so the toggle defaults to "on" until the user opts
    /// out. Idempotent — re-registering the same defaults is harmless.
    static func registerDefault(forDescriptorID id: String, visible: Bool = true) {
        UserDefaults.standard.register(defaults: [key(forDescriptorID: id): visible])
    }

    static func isVisible(descriptorID id: String) -> Bool {
        // `bool(forKey:)` returns false when the key has never been
        // touched and no register-defaults entry was ever supplied;
        // that's why `registerDefault(forDescriptorID:)` exists for
        // newly-loaded plugin ids.
        UserDefaults.standard.bool(forKey: key(forDescriptorID: id))
    }

    static func isVisible(_ kind: ProviderKind) -> Bool {
        isVisible(descriptorID: kind.rawValue)
    }

    static func setVisible(descriptorID id: String, _ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: key(forDescriptorID: id))
    }

    static func setVisible(_ kind: ProviderKind, _ visible: Bool) {
        setVisible(descriptorID: kind.rawValue, visible)
    }

    static func visibleKinds() -> [ProviderKind] {
        ProviderKind.allCases.filter { isVisible($0) }
    }
}

/// Builtin provider capability constants. The `ProviderCapabilities`
/// type itself lives in `ClaudeStatisticsKit`; only these three
/// host-bundled instances stay here. Stage 4 moves each into its
/// corresponding `*Plugin` package.
extension ProviderCapabilities {
    static let claude = ProviderCapabilities(
        supportsCost: true,
        supportsUsage: true,
        supportsProfile: true,
        supportsStatusLine: true,
        supportsExactPricing: true,
        supportsResume: true,
        supportsNewSession: true
    )

    static let codex = ProviderCapabilities(
        supportsCost: true,
        supportsUsage: true,
        supportsProfile: true,
        supportsStatusLine: true,
        supportsExactPricing: false,
        supportsResume: true,
        supportsNewSession: true
    )

    static let gemini = ProviderCapabilities(
        supportsCost: true,
        supportsUsage: true,
        supportsProfile: true,
        supportsStatusLine: true,
        supportsExactPricing: false,
        supportsResume: true,
        supportsNewSession: true
    )
}
