import Foundation

final class CodexUsageService: ProviderUsageSource {
    static let shared = CodexUsageService()

    private let authPath = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json")
    private let cacheFileName = "codex-usage-cache.json"
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let tokenRefreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// Tracks when we can next call the API (set on 429), persisted across restarts
    private(set) var retryAfter: Date? {
        get {
            if let stored = UserDefaults.standard.object(forKey: "codexUsageAPIRetryAfter") as? Date {
                return stored > Date() ? stored : nil
            }
            return nil
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date, forKey: "codexUsageAPIRetryAfter")
            } else {
                UserDefaults.standard.removeObject(forKey: "codexUsageAPIRetryAfter")
            }
        }
    }

    private init() {}

    // MARK: - ProviderUsageSource

    var dashboardURL: URL? { nil }
    var usageCacheFilePath: String? { cacheFilePath() }

    func loadCachedSnapshot() -> ProviderUsageSnapshot? {
        guard let data = FileManager.default.contents(atPath: cacheFilePath()),
              let cache = try? JSONDecoder().decode(UsageCacheFile.self, from: data),
              let timestamp = TimeInterval(cache.fetchedAt)
        else { return nil }
        return ProviderUsageSnapshot(data: cache.data, fetchedAt: Date(timeIntervalSince1970: timestamp))
    }

    func refreshSnapshot() async throws -> ProviderUsageSnapshot {
        if let retryAfter {
            if Date() < retryAfter {
                let wait = max(1, Int(ceil(retryAfter.timeIntervalSinceNow)))
                throw UsageError.rateLimited(retryInSeconds: wait)
            } else {
                self.retryAfter = nil
            }
        }

        let creds = try readAuth()
        let data = try await fetchRemoteUsage(creds: creds)
        saveToCache(data)
        return ProviderUsageSnapshot(data: data, fetchedAt: Date())
    }

    func refreshCredentials() async -> Bool {
        guard let creds = try? readAuth(), !creds.refreshToken.isEmpty else { return false }
        do {
            let newCreds = try await refreshToken(creds: creds)
            try saveAuth(newCreds)
            return true
        } catch {
            return false
        }
    }

    func resetLocalState() {
        retryAfter = nil
        try? FileManager.default.removeItem(atPath: cacheFilePath())
    }

    // MARK: - Remote API

    private func fetchRemoteUsage(creds: CodexCredentials) async throws -> UsageData {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeStatistics", forHTTPHeaderField: "User-Agent")
        if let accountId = creds.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        if http.statusCode == 429 {
            let retrySeconds = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil } ?? 900
            retryAfter = Date().addingTimeInterval(TimeInterval(retrySeconds))
            throw UsageError.rateLimited(retryInSeconds: retrySeconds)
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageError.unauthorized
        }

        guard http.statusCode == 200 else {
            throw UsageError.httpError(statusCode: http.statusCode)
        }

        retryAfter = nil

        let decoded: CodexUsageAPIResponse
        do {
            decoded = try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw UsageError.decodingFailed(detail: error.localizedDescription, raw: raw)
        }

        guard let usageData = decoded.toUsageData() else {
            throw UsageError.invalidResponse
        }
        return usageData
    }

    // MARK: - Token Refresh

    private func refreshToken(creds: CodexCredentials) async throws -> CodexCredentials {
        var request = URLRequest(url: tokenRefreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
            "scope": "openid profile email",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CodexCredentialsError.tokenRefreshFailed
        }

        return CodexCredentials(
            accessToken: json["access_token"] as? String ?? creds.accessToken,
            refreshToken: json["refresh_token"] as? String ?? creds.refreshToken,
            idToken: json["id_token"] as? String ?? creds.idToken,
            accountId: creds.accountId)
    }

    // MARK: - Auth

    private func readAuth() throws -> CodexCredentials {
        guard let data = FileManager.default.contents(atPath: authPath) else {
            throw CodexCredentialsError.notFound
        }
        return try CodexCredentials.parse(from: data)
    }

    private func saveAuth(_ creds: CodexCredentials) throws {
        guard let existing = FileManager.default.contents(atPath: authPath),
              var json = try? JSONSerialization.jsonObject(with: existing) as? [String: Any]
        else { return }

        var tokens = json["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = creds.accessToken
        tokens["refresh_token"] = creds.refreshToken
        if let idToken = creds.idToken { tokens["id_token"] = idToken }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: authPath), options: .atomic)
    }

    // MARK: - Profile

    func decodeProfile() -> UserProfile? {
        guard let creds = try? readAuth(), let idToken = creds.idToken else { return nil }

        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        let remainder = payload.count % 4
        if remainder != 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let name = json["name"] as? String
        let email = json["email"] as? String
        let openAIAuth = json["https://api.openai.com/auth"] as? [String: Any]
        let planType = openAIAuth?["chatgpt_plan_type"] as? String

        return UserProfile(
            account: ProfileAccount(
                fullName: name,
                displayName: name,
                email: email,
                hasMaxPlan: nil,
                hasProPlan: planType.map { $0 == "plus" || $0 == "pro" }),
            organization: ProfileOrganization(
                name: nil,
                organizationType: nil,
                rateLimitTier: planType,
                subscriptionStatus: "active"))
    }

    // MARK: - Cache

    private func saveToCache(_ usageData: UsageData) {
        let cache = UsageCacheFile(
            fetchedAt: String(Int(Date().timeIntervalSince1970)),
            data: usageData)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: URL(fileURLWithPath: cacheFilePath()), options: .atomic)
    }

    private func cacheFilePath() -> String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-statistics")
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        return (dir as NSString).appendingPathComponent(cacheFileName)
    }
}

// MARK: - API Response

private struct CodexUsageAPIResponse: Decodable {
    let planType: String?
    let rateLimit: RateLimitDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }

    struct RateLimitDetails: Decodable {
        let primaryWindow: WindowSnapshot?
        let secondaryWindow: WindowSnapshot?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct WindowSnapshot: Decodable {
        let usedPercent: Int
        let resetAt: Int
        let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    func toUsageData() -> UsageData? {
        guard let rateLimit else { return nil }

        var fiveHour: UsageWindow?
        var sevenDay: UsageWindow?

        for window in [rateLimit.primaryWindow, rateLimit.secondaryWindow].compactMap({ $0 }) {
            let usageWindow = makeUsageWindow(from: window)
            // ≤ 6 hours → five-hour window; ≥ 5 days → seven-day window
            if window.limitWindowSeconds <= 6 * 3600 {
                fiveHour = usageWindow
            } else {
                sevenDay = usageWindow
            }
        }

        guard fiveHour != nil || sevenDay != nil else { return nil }
        return UsageData(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            providerBuckets: nil,
            extraUsage: nil)
    }

    private func makeUsageWindow(from window: WindowSnapshot) -> UsageWindow {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let resetsAt = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(window.resetAt)))
        return UsageWindow(utilization: Double(window.usedPercent), resetsAt: resetsAt)
    }
}

// MARK: - Credentials

private struct CodexCredentials {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let accountId: String?

    static func parse(from data: Data) throws -> CodexCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexCredentialsError.invalid
        }

        // Plain API key mode
        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return CodexCredentials(accessToken: apiKey, refreshToken: "", idToken: nil, accountId: nil)
        }

        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty
        else {
            throw CodexCredentialsError.missingTokens
        }

        return CodexCredentials(
            accessToken: accessToken,
            refreshToken: tokens["refresh_token"] as? String ?? "",
            idToken: tokens["id_token"] as? String,
            accountId: tokens["account_id"] as? String)
    }
}

private enum CodexCredentialsError: LocalizedError {
    case notFound
    case invalid
    case missingTokens
    case tokenRefreshFailed

    var errorDescription: String? {
        switch self {
        case .notFound: "Codex auth.json not found. Run `codex` to log in."
        case .invalid: "Codex auth.json is not valid JSON."
        case .missingTokens: "Codex auth.json exists but contains no tokens."
        case .tokenRefreshFailed: "Failed to refresh Codex token. Run `codex` to log in again."
        }
    }
}
