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

/// Canonical tool-name vocabulary shared across providers. Each provider's
/// alias table funnels its raw names into these values, and consumers that
/// need a UI label use `displayName(for:)` here — keeping pretty capitalization
/// in one place instead of duplicated across transcript parsers and formatters.
enum CanonicalToolName {
    /// Tool-name fallback used by callers that lack a `ProviderKind` context.
    /// Tries every registered provider's alias table in turn; returns the
    /// lower-cased normalized name when no provider recognizes the alias.
    static func resolve(_ raw: String?) -> String {
        guard let raw else { return "" }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        guard !normalized.isEmpty else { return "" }
        for kind in ProviderKind.allCases {
            if let mapped = kind.descriptor.resolveToolAlias(normalized) {
                return mapped
            }
        }
        return normalized
    }

    /// Pretty label for a canonical tool name (e.g. `"edit"` → `"Edit"`).
    /// Used by transcript parsers and any UI that wants a consistent verb
    /// across providers. Unknown canonicals get a title-cased fallback.
    static func displayName(for canonical: String) -> String {
        switch canonical {
        case "bash": return "Bash"
        case "read": return "Read"
        case "write": return "Write"
        case "edit", "multiedit": return "Edit"
        case "grep": return "Grep"
        case "glob": return "Glob"
        case "ls": return "List"
        case "webfetch": return "Fetch"
        case "websearch": return "Search"
        case "task", "agent": return "Agent"
        case "help": return "Help"
        case "todowrite": return "Todo"
        default:
            guard let first = canonical.first else { return canonical }
            return String(first).uppercased() + canonical.dropFirst()
        }
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

struct ProviderCapabilities: Codable, Equatable {
    let supportsCost: Bool
    let supportsUsage: Bool
    let supportsProfile: Bool
    let supportsStatusLine: Bool
    let supportsExactPricing: Bool
    let supportsResume: Bool
    let supportsNewSession: Bool

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
