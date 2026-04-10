import Foundation

struct OpenAIUsageData: Codable, Equatable {
    let currentWindow: OpenAIUsageWindow?
    let weeklyWindow: OpenAIUsageWindow?
    let planType: String?
    let accountEmail: String?

    static func decodeUsageResponse(from data: Data, accountEmail: String?) -> OpenAIUsageData? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = OpenAIUsageData.iso8601Date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO8601 date: \(value)"
                )
            }
            return date
        }

        do {
            let response = try decoder.decode(OpenAIUsageResponse.self, from: data)
            return OpenAIUsageData(
                currentWindow: response.rateLimit?.primaryWindow.flatMap { payload in
                    guard let utilization = payload.usedPercent else { return nil }
                    return OpenAIUsageWindow(utilization: utilization, resetAt: payload.resetAt)
                },
                weeklyWindow: response.rateLimit?.secondaryWindow.flatMap { payload in
                    guard let utilization = payload.usedPercent else { return nil }
                    return OpenAIUsageWindow(utilization: utilization, resetAt: payload.resetAt)
                },
                planType: response.planType,
                accountEmail: accountEmail
            )
        } catch {
            return nil
        }
    }

    static func iso8601Date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

struct OpenAIUsageWindow: Codable, Equatable {
    let utilization: Double
    let resetAt: Date?
}

struct OpenAIUsageCacheFile: Codable {
    let fetchedAt: Date
    let data: OpenAIUsageData
}

private struct OpenAIUsageResponse: Codable {
    let rateLimit: OpenAIRateLimitResponse?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
        case planType = "plan_type"
    }
}

private struct OpenAIRateLimitResponse: Codable {
    let primaryWindow: OpenAIUsageWindowResponse?
    let secondaryWindow: OpenAIUsageWindowResponse?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct OpenAIUsageWindowResponse: Codable {
    let usedPercent: Double?
    let resetAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent)
        resetAt = try container.decodeIfPresent(OpenAIResetAt.self, forKey: .resetAt)?.dateValue
    }
}

private struct OpenAIResetAt: Decodable {
    let dateValue: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let seconds = try? container.decode(Double.self) {
            dateValue = Date(timeIntervalSince1970: OpenAIResetAt.normalizedEpoch(seconds))
            return
        }

        if let string = try? container.decode(String.self) {
            if let date = OpenAIUsageData.iso8601Date(from: string) {
                dateValue = date
                return
            }
            if let seconds = Double(string) {
                dateValue = Date(timeIntervalSince1970: OpenAIResetAt.normalizedEpoch(seconds))
                return
            }
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected numeric epoch or ISO8601 date for reset_at"
        )
    }

    private static func normalizedEpoch(_ value: Double) -> TimeInterval {
        value > 10_000_000_000 ? value / 1_000 : value
    }
}
