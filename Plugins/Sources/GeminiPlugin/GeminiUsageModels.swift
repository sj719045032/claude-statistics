import Foundation

struct GeminiQuotaContext {
    let quota: GeminiQuotaResponse
    let tierName: String?
}

struct GeminiSettings: Decodable {
    let security: SecurityConfig?
    let model: ModelConfig?

    var selectedAuthType: GeminiAuthType {
        GeminiAuthType(rawValue: security?.auth?.selectedType ?? "") ?? .unknown
    }

    var modelName: String? {
        model?.name
    }

    struct SecurityConfig: Decodable {
        let auth: AuthConfig?
    }

    struct AuthConfig: Decodable {
        let selectedType: String?
    }

    struct ModelConfig: Decodable {
        let name: String?
    }
}

enum GeminiAuthType: String {
    case oauthPersonal = "oauth-personal"
    case geminiAPIKey = "gemini-api-key"
    case vertexAI = "vertex-ai"
    case unknown

    var displayName: String {
        switch self {
        case .oauthPersonal: return "Google Account"
        case .geminiAPIKey: return "Gemini API Key"
        case .vertexAI: return "Vertex AI"
        case .unknown: return "Gemini"
        }
    }
}

struct GeminiOAuthCredentials: Codable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let expiryDate: Double?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiryDate = "expiry_date"
        case tokenType = "token_type"
    }

    var isExpired: Bool {
        guard let expiryDate else { return false }
        return expiryDate <= (Date().timeIntervalSince1970 * 1000) + 60_000
    }
}

struct GeminiOAuthRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

struct GoogleAccounts: Decodable {
    let active: String?
}

struct GeminiLoadCodeAssistRequest: Encodable {
    let cloudaicompanionProject: String?
    let metadata: Metadata

    struct Metadata: Encodable {
        let ideType: String
        let platform: String
        let pluginType: String
        let duetProject: String?
    }
}

struct GeminiQuotaRequest: Encodable {
    let project: String
}

struct GeminiLoadCodeAssistResponse: Decodable {
    let currentTier: GeminiTier?
    let paidTier: GeminiTier?
    let cloudaicompanionProject: String?
}

struct GeminiTier: Decodable {
    let id: String?
    let name: String?
}

struct GeminiQuotaResponse: Decodable {
    let buckets: [GeminiQuotaBucket]?
}

struct GeminiQuotaBucket: Decodable {
    let modelId: String?
    let remainingAmount: Double?
    let limitAmount: Double?
    let remainingFraction: Double?
    let resetTime: String?
    let metric: String?
    let quotaMetric: String?

    enum CodingKeys: String, CodingKey {
        case modelId
        case remainingAmount = "remaining"
        case remainingAmountAlt = "remainingAmount"
        case limitAmount = "limit"
        case limitAmountAlt = "limitAmount"
        case remainingFraction
        case resetTime
        case metric
        case quotaMetric
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        remainingFraction = Self.decodeDouble(container, forKey: .remainingFraction)
        resetTime = try container.decodeIfPresent(String.self, forKey: .resetTime)
        metric = try container.decodeIfPresent(String.self, forKey: .metric)
        quotaMetric = try container.decodeIfPresent(String.self, forKey: .quotaMetric)

        if let val = Self.decodeDouble(container, forKey: .remainingAmount) {
            remainingAmount = val
        } else {
            remainingAmount = Self.decodeDouble(container, forKey: .remainingAmountAlt)
        }

        if let val = Self.decodeDouble(container, forKey: .limitAmount) {
            limitAmount = val
        } else {
            limitAmount = Self.decodeDouble(container, forKey: .limitAmountAlt)
        }
    }

    var inferredLimitAmount: Double? {
        guard let remainingAmount,
              let remainingFraction,
              remainingFraction > 0 else {
            return nil
        }
        return remainingAmount / remainingFraction
    }

    var effectiveUnit: String? {
        if let val = metric, !val.isEmpty { return val }
        if let val = quotaMetric, !val.isEmpty { return val }

        let lower = modelId?.lowercased() ?? ""
        if lower.contains("-rpm") { return "RPM" }
        if lower.contains("-tpm") { return "TPM" }
        if lower.contains("-rpd") { return "RPD" }
        if lower.contains("-tpd") { return "TPD" }

        return nil
    }

    private static func decodeDouble(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Double(trimmed.replacingOccurrences(of: ",", with: "")) {
                return number
            }
        }
        return nil
    }
}

struct GeminiLogEntry: Decodable {
    let type: String?
    let message: String?
    let timestamp: String?

    var timestampDate: Date? {
        guard let timestamp else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}
