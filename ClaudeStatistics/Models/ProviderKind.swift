import Foundation
import SwiftUI
import ClaudeStatisticsKit

/// Open string-id wrapper, formerly a closed enum. Builtin ids are
/// exposed as `static let` constants so `kind == .claude` / dot-syntax
/// keep working, but any string is now constructible — third-party
/// plugin descriptors flow through the same type. The `var descriptor`
/// accessor falls back to the Claude descriptor for unknown ids,
/// matching the legacy "default to Claude" contract that historically
/// lived in `ProviderKind(rawValue:) ?? .claude` callsites.
struct ProviderKind: RawRepresentable, Hashable, Codable, Identifiable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    static let claude = ProviderKind(rawValue: "claude")!
    static let codex  = ProviderKind(rawValue: "codex")!
    static let gemini = ProviderKind(rawValue: "gemini")!

    /// Replaces enum's auto-derived `allCases`. Iteration order is the
    /// canonical display order Claude / Codex / Gemini.
    static let allBuiltins: [ProviderKind] = [.claude, .codex, .gemini]

    var id: String { rawValue }

    var descriptor: ProviderDescriptor {
        switch rawValue {
        case "claude": return .claude
        default:
            // Any extracted plugin (Codex, Gemini, third-party) registers
            // its descriptor into `PluginDescriptorStore` from `init()`.
            // Fall back to a minimal placeholder using `rawValue` as id
            // when the store hasn't been populated — `allKnownDescriptors`
            // dedups by id, so handing back `.claude` would alias every
            // unloaded plugin onto the Claude slot. The placeholder
            // copies Claude's UI styling (we only need a usable
            // `iconAssetName` / `accentColor` if any UI surface still
            // looks at it before plugin load).
            return PluginDescriptorStore.descriptor(for: rawValue)
                ?? ProviderDescriptor.placeholder(id: rawValue)
        }
    }
}

extension ProviderDescriptor {
    /// Best-effort placeholder used by `ProviderKind.descriptor` when
    /// the plugin owning `id` hasn't pushed its descriptor into
    /// `PluginDescriptorStore` yet (typical only for the brief window
    /// between AppState init and PluginRegistry load, or in unit tests
    /// that exercise host code without loading the bundle).
    static func placeholder(id: String) -> ProviderDescriptor {
        ProviderDescriptor(
            id: id,
            displayName: id.capitalized,
            iconAssetName: "ClaudeProviderIcon",
            accentColor: Color(red: 0.5, green: 0.5, blue: 0.5),
            badgeColor: Color(red: 0.5, green: 0.5, blue: 0.5),
            notchEnabledDefaultsKey: "notch.enabled.\(id)",
            capabilities: ProviderCapabilities(
                supportsCost: true,
                supportsUsage: true,
                supportsProfile: true,
                supportsStatusLine: true,
                supportsExactPricing: false,
                supportsResume: true,
                supportsNewSession: true
            ),
            resolveToolAlias: { PluginToolAliasStore.canonical($0, for: id) }
        )
    }
}

/// Convenience for kernel callers that want the legacy registry-free
/// resolve flavour (no plugin id required, just walks every builtin
/// provider's alias table). New code should prefer
/// `ClaudeStatisticsKit.CanonicalToolName.resolve(_:descriptors:)`
/// directly with the desired descriptor set.
enum HostCanonicalToolName {
    static func resolve(_ raw: String?) -> String {
        CanonicalToolName.resolve(raw, descriptors: ProviderKind.allBuiltins.map(\.descriptor))
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
        for kind in ProviderKind.allBuiltins {
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
}

/// Builtin provider capability constants. Only Claude remains here
/// while its adapter still ships from the host module. Codex and
/// Gemini inline their capabilities inside the plugin descriptor.
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
}
