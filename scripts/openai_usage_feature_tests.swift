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
        "preferred_username": "user@example.com"
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

    expect(state.status == .configured, "Expected chatgpt auth to be treated as configured")
    expect(state.isConfigured, "Expected configured auth to report isConfigured")
    expect(state.accountId == "acct_789", "Expected account_id to be decoded from auth.json")
    expect(
        state.accountEmail == "user@example.com",
        "Expected account_email to fall back to preferred_username when email is absent"
    )
    expect(state.accessToken == "access-123", "Expected access token to be preserved")
    expect(state.refreshToken == "refresh-456", "Expected refresh token to be preserved")
    expect(state.idToken == token, "Expected id token to be preserved")

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
        OpenAICredentialService.decodeAuthState(from: apiKeyData, now: isoDate("2026-04-08T10:00:00Z")).status == .unsupportedMode,
        "Expected api_key auth mode to be rejected as unsupported"
    )

    let invalidJSON: [String: Any] = [
        "auth_mode": "chatgpt",
        "tokens": [
            "refresh_token": "refresh-456",
            "id_token": token,
            "account_id": "acct_789"
        ]
    ]

    let invalidData = try JSONSerialization.data(withJSONObject: invalidJSON, options: [.sortedKeys])
    expect(
        OpenAICredentialService.decodeAuthState(from: invalidData, now: isoDate("2026-04-08T10:00:00Z")).status == .invalidAuth,
        "Expected missing access token payload to be rejected as invalid"
    )

    let missingURL = URL(fileURLWithPath: "/tmp/openai-auth-missing-\(UUID().uuidString).json")
    expect(
        OpenAICredentialService.shared.loadAuthState(from: missingURL).status == .notFound,
        "Expected missing auth file to report notFound"
    )
}

func runOpenAIUsageMappingTests() throws {
    let cases: [(resetAt: Any, expected: Date)] = [
        (1_766_664_000, Date(timeIntervalSince1970: 1_766_664_000)),
        (1_766_664_000_000, Date(timeIntervalSince1970: 1_766_664_000)),
        ("1766664000", Date(timeIntervalSince1970: 1_766_664_000)),
        ("2026-04-08T15:00:00Z", isoDate("2026-04-08T15:00:00Z"))
    ]

    for (index, entry) in cases.enumerated() {
        let json: [String: Any] = [
            "rate_limit": [
                "primary_window": [
                    "used_percent": 31.8,
                    "reset_at": entry.resetAt
                ],
                "secondary_window": [
                    "used_percent": 64.2,
                    "reset_at": entry.resetAt
                ]
            ],
            "plan_type": "plus"
        ]

        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let usage = OpenAIUsageData.decodeUsageResponse(from: data, accountEmail: "user@example.com")

        expect(usage?.currentWindow?.utilization == 31.8, "Expected primary_window.used_percent to map to currentWindow.utilization (case \(index))")
        expect(
            usage?.currentWindow?.resetAt == entry.expected,
            "Expected primary_window.reset_at to map to currentWindow.resetAt (case \(index))"
        )
        expect(usage?.weeklyWindow?.utilization == 64.2, "Expected secondary_window.used_percent to map to weeklyWindow.utilization (case \(index))")
        expect(
            usage?.weeklyWindow?.resetAt == entry.expected,
            "Expected secondary_window.reset_at to map to weeklyWindow.resetAt (case \(index))"
        )
        expect(usage?.planType == "plus", "Expected plan_type to be preserved (case \(index))")
        expect(usage?.accountEmail == "user@example.com", "Expected accountEmail to be attached during mapping (case \(index))")
    }
}

final class FakeOpenAIUsageService: OpenAIUsageServicing {
    var authState: OpenAIAuthState
    var cacheResponse: (data: OpenAIUsageData, fetchedAt: Date)?
    var fetchResult: Result<OpenAIUsageData, Error> = .success(
        OpenAIUsageData(
            currentWindow: nil,
            weeklyWindow: nil,
            planType: nil,
            accountEmail: nil
        )
    )
    var fetchDelayNanoseconds: UInt64 = 0
    private(set) var fetchCallCount = 0

    init(
        authState: OpenAIAuthState,
        cacheResponse: (data: OpenAIUsageData, fetchedAt: Date)? = nil
    ) {
        self.authState = authState
        self.cacheResponse = cacheResponse
    }

    func loadCache() -> (data: OpenAIUsageData, fetchedAt: Date)? {
        cacheResponse
    }

    func fetchUsage() async throws -> OpenAIUsageData {
        fetchCallCount += 1
        if fetchDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: fetchDelayNanoseconds)
        }
        return try fetchResult.get()
    }
}

func configuredAuthState() -> OpenAIAuthState {
    OpenAIAuthState(
        status: .configured,
        accountId: "acct_789",
        accountEmail: "user@example.com",
        accessToken: "access-123",
        refreshToken: "refresh-456",
        idToken: "header.payload.signature"
    )
}

@MainActor
func runOpenAIUsageViewModelTests() async {
    let cachedCurrentReset = Date().addingTimeInterval(90_000)
    let cachedWeeklyReset = Date().addingTimeInterval(200_000)
    let cached = OpenAIUsageData(
        currentWindow: OpenAIUsageWindow(utilization: 31.8, resetAt: cachedCurrentReset),
        weeklyWindow: OpenAIUsageWindow(utilization: 64.2, resetAt: cachedWeeklyReset),
        planType: "plus",
        accountEmail: "user@example.com"
    )

    let fake = FakeOpenAIUsageService(
        authState: configuredAuthState(),
        cacheResponse: (data: cached, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    )
    let vm = OpenAIUsageViewModel(service: fake)

    vm.setup()

    expect(vm.authState.status == .configured, "Expected setup to preserve configured auth state")
    expect(vm.isConfigured, "Expected configured auth state to report isConfigured")
    expect(vm.usageData == cached, "Expected setup to load cached usage")
    expect(vm.currentWindowPercent == 31.8, "Expected currentWindowPercent to surface cached current usage")
    expect(vm.weeklyPercent == 64.2, "Expected weeklyPercent to surface cached weekly usage")
    expect(vm.currentWindowResetCountdown?.hasPrefix("1d") == true, "Expected currentWindowResetCountdown to be derived from cached reset date")
    expect(vm.weeklyResetCountdown?.hasPrefix("2d") == true, "Expected weeklyResetCountdown to be derived from cached reset date")
    expect(vm.hasDisplayableUsage, "Expected cached usage to be displayable")

    let refreshed = OpenAIUsageData(
        currentWindow: OpenAIUsageWindow(utilization: 12.5, resetAt: Date(timeIntervalSinceNow: 3700)),
        weeklyWindow: OpenAIUsageWindow(utilization: 34.5, resetAt: Date(timeIntervalSinceNow: 5400)),
        planType: "pro",
        accountEmail: "user@example.com"
    )

    fake.fetchResult = .success(refreshed)
    await vm.refresh()

    expect(fake.fetchCallCount == 1, "Expected refresh to call through to the injected service")
    expect(vm.usageData == refreshed, "Expected refresh to replace cached data with fetched data")
    expect(vm.currentWindowPercent == 12.5, "Expected currentWindowPercent to reflect fetched data")
    expect(vm.weeklyPercent == 34.5, "Expected weeklyPercent to reflect fetched data")
    expect(vm.currentWindowResetCountdown?.hasPrefix("1h") == true, "Expected currentWindowResetCountdown to be derived from fetched data")
    expect(vm.weeklyResetCountdown?.hasPrefix("1h") == true, "Expected weeklyResetCountdown to be derived from fetched data")

    let fallbackFake = FakeOpenAIUsageService(
        authState: configuredAuthState(),
        cacheResponse: (data: cached, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    )
    fallbackFake.fetchResult = .failure(NSError(domain: "OpenAI", code: 500, userInfo: [
        NSLocalizedDescriptionKey: "boom"
    ]))
    let fallbackVM = OpenAIUsageViewModel(service: fallbackFake)

    fallbackVM.setup()
    await fallbackVM.forceRefresh()

    expect(fallbackFake.fetchCallCount == 1, "Expected forceRefresh to call through to the injected service")
    expect(fallbackVM.usageData == cached, "Expected failed forceRefresh to retain cached data")
    expect(fallbackVM.errorMessage == "boom", "Expected failed forceRefresh to preserve the service error")
    expect(fallbackVM.hasDisplayableUsage, "Expected cached fallback data to remain displayable")

    let recoveringFake = FakeOpenAIUsageService(
        authState: OpenAIAuthState(
            status: .notFound,
            accountId: nil,
            accountEmail: nil,
            accessToken: nil,
            refreshToken: nil,
            idToken: nil
        )
    )
    let recoveringVM = OpenAIUsageViewModel(service: recoveringFake)

    recoveringVM.setup()
    expect(recoveringVM.authState.status == .notFound, "Expected initial setup to reflect missing auth")
    expect(!recoveringVM.isConfigured, "Expected missing auth to start unconfigured")

    recoveringFake.authState = configuredAuthState()
    recoveringFake.fetchResult = .success(refreshed)
    await recoveringVM.forceRefresh()

    expect(recoveringVM.authState.status == .configured, "Expected forceRefresh to resync auth state from the service")
    expect(recoveringVM.isConfigured, "Expected forceRefresh to transition the VM to configured")
    expect(recoveringVM.usageData == refreshed, "Expected recovered auth to allow a successful fetch")
    expect(recoveringFake.fetchCallCount == 1, "Expected recovered auth to trigger a fetch")

    let overlappingFake = FakeOpenAIUsageService(authState: configuredAuthState())
    overlappingFake.fetchResult = .success(refreshed)
    overlappingFake.fetchDelayNanoseconds = 100_000_000
    let overlappingVM = OpenAIUsageViewModel(service: overlappingFake)

    overlappingVM.setup()
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            await overlappingVM.forceRefresh()
        }
        group.addTask {
            await overlappingVM.forceRefresh()
        }
    }

    expect(overlappingFake.fetchCallCount == 1, "Expected overlapping refresh attempts to coalesce into one fetch")
    expect(overlappingVM.usageData == refreshed, "Expected overlapping refresh guard to keep the successful result")

    let states: [OpenAIAuthStatus] = [.notFound, .unsupportedMode, .invalidAuth]
    for state in states {
        let authFake = FakeOpenAIUsageService(
            authState: OpenAIAuthState(
                status: state,
                accountId: nil,
                accountEmail: nil,
                accessToken: nil,
                refreshToken: nil,
                idToken: nil
            )
        )
        let authVM = OpenAIUsageViewModel(service: authFake)
        authVM.setup()

        expect(authVM.authState.status == state, "Expected setup to preserve auth status \(state)")
        expect(!authVM.isConfigured, "Expected \(state) auth status to be treated as not configured")
        expect(authVM.hasDisplayableUsage == false, "Expected \(state) auth status to remain hidden without usage")
        expect(authFake.fetchCallCount == 0, "Expected \(state) auth status to skip fetch attempts")
    }
}

@main
struct OpenAIUsageFeatureTestsRunner {
    @MainActor
    static func main() async {
        do {
            try runOpenAIAuthParsingTests()
            try runOpenAIUsageMappingTests()
            await runOpenAIUsageViewModelTests()
            print("openai_usage_feature_tests passed")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
