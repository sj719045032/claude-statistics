import Foundation
import SwiftUI
import ClaudeStatisticsKit

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex
    case gemini

    var id: String { rawValue }

    /// The descriptor for this kind. Stage-1A introduces this as the new
    /// single source of truth; the legacy property accessors below now
    /// forward to it. Stage 1D migrates all `switch self` consumers to
    /// read `descriptor.<field>` directly and the legacy accessors will
    /// be deprecated once those migrations land.
    var descriptor: ProviderDescriptor {
        switch self {
        case .claude: return .claude
        case .codex:  return .codex
        case .gemini: return .gemini
        }
    }

    var displayName: String { descriptor.displayName }

    /// UserDefaults key for this provider's notch master switch. Anchored on
    /// the enum's rawValue so adding a new provider needs no central table
    /// edit — each provider owns its own string.
    var notchEnabledDefaultsKey: String { descriptor.notchEnabledDefaultsKey }

    /// Asset name of the monochrome template icon used to represent this
    /// provider in the menu bar strip. Template-rendered so the icon
    /// inherits the status bar's tint across dark/light mode.
    var statusIconAssetName: String { descriptor.iconAssetName }

    /// Brand accent color — used as a subtle tint for the provider icon
    /// when not inheriting the status bar's template color.
    var accentColor: Color { descriptor.accentColor }
}

extension ProviderKind {
    /// Lower-cased canonical tool name for this provider's raw tool name —
    /// `Edit` / `apply_patch` / `replace` all collapse to `"edit"`, `Read` /
    /// `read_file` collapse to `"read"`, etc. The alias tables live in each
    /// provider's own file (`ClaudeToolNames` / `CodexToolNames` /
    /// `GeminiToolNames`) and are exposed through `ProviderDescriptor
    /// .resolveToolAlias` so adding a new provider does not touch this
    /// shared code. Unknown names pass through as lower-cased.
    func canonicalToolName(_ raw: String?) -> String {
        guard let raw else { return "" }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        guard !normalized.isEmpty else { return "" }
        if let mapped = descriptor.resolveToolAlias(normalized) {
            return mapped
        }
        return normalized
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
/// Defaults to all three enabled so a fresh install shows every configured
/// provider; the user can hide individual providers from Settings.
enum MenuBarPreferences {
    static func key(for kind: ProviderKind) -> String {
        "menuBar.visible.\(kind.rawValue)"
    }

    static func register() {
        var defaults: [String: Any] = [:]
        for kind in ProviderKind.allCases {
            defaults[key(for: kind)] = true
        }
        UserDefaults.standard.register(defaults: defaults)
    }

    static func isVisible(_ kind: ProviderKind) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: kind))
    }

    static func setVisible(_ kind: ProviderKind, _ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: key(for: kind))
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
