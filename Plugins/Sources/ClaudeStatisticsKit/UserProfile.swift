import Foundation

/// User profile a Provider plugin returns from
/// `AccountProvider.fetchProfile()`. Account info (name / email /
/// plan flags) and organization info (tier / type) are both optional
/// because Codex / Gemini may not expose all fields the way
/// Anthropic's API does.
public struct UserProfile: Codable, Sendable {
    public let account: ProfileAccount?
    public let organization: ProfileOrganization?

    public init(account: ProfileAccount? = nil, organization: ProfileOrganization? = nil) {
        self.account = account
        self.organization = organization
    }
}

public struct ProfileAccount: Codable, Sendable {
    public let fullName: String?
    public let displayName: String?
    public let email: String?
    public let hasMaxPlan: Bool?
    public let hasProPlan: Bool?

    public init(
        fullName: String? = nil,
        displayName: String? = nil,
        email: String? = nil,
        hasMaxPlan: Bool? = nil,
        hasProPlan: Bool? = nil
    ) {
        self.fullName = fullName
        self.displayName = displayName
        self.email = email
        self.hasMaxPlan = hasMaxPlan
        self.hasProPlan = hasProPlan
    }

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case displayName = "display_name"
        case email
        case hasMaxPlan = "has_claude_max"
        case hasProPlan = "has_claude_pro"
    }
}

public struct ProfileOrganization: Codable, Sendable {
    public let name: String?
    public let organizationType: String?
    public let rateLimitTier: String?
    public let subscriptionStatus: String?

    public init(
        name: String? = nil,
        organizationType: String? = nil,
        rateLimitTier: String? = nil,
        subscriptionStatus: String? = nil
    ) {
        self.name = name
        self.organizationType = organizationType
        self.rateLimitTier = rateLimitTier
        self.subscriptionStatus = subscriptionStatus
    }

    enum CodingKeys: String, CodingKey {
        case name
        case organizationType = "organization_type"
        case rateLimitTier = "rate_limit_tier"
        case subscriptionStatus = "subscription_status"
    }

    public var orgTypeDisplayName: String {
        if let organizationType, organizationType.contains(" "), organizationType != organizationType.lowercased() {
            return organizationType
        }
        switch organizationType {
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        case "claude_pro": return "Pro"
        default: return organizationType?.replacingOccurrences(of: "claude_", with: "").capitalized ?? "–"
        }
    }

    public var tierDisplayName: String {
        guard let tier = rateLimitTier else { return "–" }
        if tier.contains(" "), tier != tier.lowercased() {
            return tier
        }
        if tier.contains("claude_max_5x") { return "Max 5x" }
        if tier.contains("claude_max") { return "Max" }
        if tier.contains("claude_pro") { return "Pro" }
        return tier.replacingOccurrences(of: "default_", with: "")
            .replacingOccurrences(of: "claude_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
