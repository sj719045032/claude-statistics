import Foundation
import SwiftUI

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    /// UserDefaults key for this provider's notch master switch. Anchored on
    /// the enum's rawValue so adding a new provider needs no central table
    /// edit — each provider owns its own string.
    var notchEnabledDefaultsKey: String { "notch.enabled.\(rawValue)" }

    /// Asset name of the monochrome template icon used to represent this
    /// provider in the menu bar strip. Template-rendered so the icon
    /// inherits the status bar's tint across dark/light mode.
    var statusIconAssetName: String {
        switch self {
        case .claude: return "ClaudeProviderIcon"
        case .codex: return "CodexProviderIcon"
        case .gemini: return "GeminiProviderIcon"
        }
    }

    /// Brand accent color — used as a subtle tint for the provider icon
    /// when not inheriting the status bar's template color.
    var accentColor: Color {
        switch self {
        case .claude: return Color(red: 0.83, green: 0.40, blue: 0.25)
        case .codex: return Color(red: 0.10, green: 0.66, blue: 0.50)
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)
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
