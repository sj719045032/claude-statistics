import Foundation

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
