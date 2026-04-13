import Foundation

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

struct ProviderCapabilities: Codable, Equatable {
    let supportsCost: Bool
    let supportsUsageWindows: Bool
    let supportsProfile: Bool
    let supportsStatusLine: Bool
    let supportsExactPricing: Bool
    let supportsResume: Bool
    let supportsNewSession: Bool

    static let claude = ProviderCapabilities(
        supportsCost: true,
        supportsUsageWindows: true,
        supportsProfile: true,
        supportsStatusLine: true,
        supportsExactPricing: true,
        supportsResume: true,
        supportsNewSession: true
    )

    static let codex = ProviderCapabilities(
        supportsCost: true,
        supportsUsageWindows: true,
        supportsProfile: true,
        supportsStatusLine: true,
        supportsExactPricing: false,
        supportsResume: true,
        supportsNewSession: true
    )
}
