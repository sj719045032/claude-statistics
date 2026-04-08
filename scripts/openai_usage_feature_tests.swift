import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        fatalError("Invalid ISO8601 date: \(value)")
    }
    return date
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func jwt(payload: [String: Any]) throws -> String {
    let header = base64URL(Data(#"{"alg":"none","typ":"JWT"}"#.utf8))
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
    return [header, base64URL(payloadData), "signature"].joined(separator: ".")
}

func runOpenAIAuthParsingTests() throws {
    let token = try jwt(payload: [
        "email": "user@example.com"
    ])

    let json: [String: Any] = [
        "OPENAI_API_KEY": NSNull(),
        "auth_mode": "chatgpt",
        "last_refresh": "2026-04-08T09:00:00Z",
        "tokens": [
            "access_token": "access-123",
            "refresh_token": "refresh-456",
            "id_token": token,
            "account_id": "acct_789"
        ]
    ]

    let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    let state = OpenAICredentialService.decodeAuthState(from: data, now: isoDate("2026-04-08T10:00:00Z"))

    expect(state?.configured == true, "Expected chatgpt auth to be treated as configured")
    expect(state?.accountId == "acct_789", "Expected account_id to be decoded from auth.json")
    expect(state?.accountEmail == "user@example.com", "Expected email to be decoded from the JWT payload")
    expect(state?.accessToken == "access-123", "Expected access token to be preserved")
    expect(state?.refreshToken == "refresh-456", "Expected refresh token to be preserved")
    expect(state?.idToken == token, "Expected id token to be preserved")

    let apiKeyJSON: [String: Any] = [
        "auth_mode": "api_key",
        "tokens": [
            "access_token": "access-123",
            "refresh_token": "refresh-456",
            "id_token": token,
            "account_id": "acct_789"
        ]
    ]

    let apiKeyData = try JSONSerialization.data(withJSONObject: apiKeyJSON, options: [.sortedKeys])
    expect(
        OpenAICredentialService.decodeAuthState(from: apiKeyData, now: isoDate("2026-04-08T10:00:00Z")) == nil,
        "Expected api_key auth mode to be rejected"
    )
}

func runOpenAIUsageMappingTests() throws {
    let json: [String: Any] = [
        "rate_limit": [
            "primary_window": [
                "used_percent": 31.8,
                "reset_at": "2026-04-08T15:00:00Z"
            ],
            "secondary_window": [
                "used_percent": 64.2,
                "reset_at": "2026-04-15T00:00:00Z"
            ]
        ],
        "plan_type": "plus"
    ]

    let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    let usage = OpenAIUsageData.decodeUsageResponse(from: data, accountEmail: "user@example.com")

    expect(usage?.currentWindow?.utilization == 31.8, "Expected primary_window.used_percent to map to currentWindow.utilization")
    expect(
        usage?.currentWindow?.resetAt == isoDate("2026-04-08T15:00:00Z"),
        "Expected primary_window.reset_at to map to currentWindow.resetAt"
    )
    expect(usage?.weeklyWindow?.utilization == 64.2, "Expected secondary_window.used_percent to map to weeklyWindow.utilization")
    expect(
        usage?.weeklyWindow?.resetAt == isoDate("2026-04-15T00:00:00Z"),
        "Expected secondary_window.reset_at to map to weeklyWindow.resetAt"
    )
    expect(usage?.planType == "plus", "Expected plan_type to be preserved")
    expect(usage?.accountEmail == "user@example.com", "Expected accountEmail to be attached during mapping")
}

@main
struct OpenAIUsageFeatureTestsRunner {
    static func main() throws {
        try runOpenAIAuthParsingTests()
        try runOpenAIUsageMappingTests()
        print("openai_usage_feature_tests passed")
    }
}
