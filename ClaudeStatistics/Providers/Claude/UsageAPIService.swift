import Foundation

final class UsageAPIService: ProviderUsageSource {
    static let shared = UsageAPIService()

    private let apiURL = "https://api.anthropic.com/api/oauth/usage"
    private let profileURL = "https://api.anthropic.com/api/oauth/profile"
    private let cacheFileName = "usage-cache.json"

    private init() {}

    // MARK: - Fetch from API

    func fetchUsage() async throws -> UsageData {
        guard let tokenInfo = CredentialService.shared.accessTokenInfo() else {
            throw UsageError.noCredentials
        }
        DiagnosticLogger.shared.info("Claude usage request using \(tokenInfo.source.rawValue) credentials")

        guard let url = URL(string: apiURL) else {
            throw UsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(tokenInfo.token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            // Parse Retry-After header, default to 15 minutes (API rarely returns this header)
            let retrySeconds = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil } ?? 900
            throw UsageError.rateLimited(retryInSeconds: retrySeconds)
        }

        if httpResponse.statusCode == 401 {
            throw UsageError.unauthorized
        }

        guard httpResponse.statusCode == 200 else {
            throw UsageError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let usageData: UsageData
        do {
            usageData = try decoder.decode(UsageAPIResponse.self, from: data).asUsageData
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw UsageError.decodingFailed(detail: error.localizedDescription, raw: raw)
        }

        // Cache the result
        saveToCache(usageData)

        return usageData
    }

    // MARK: - Token Refresh

    /// Trigger Claude Code CLI to refresh the OAuth token
    func refreshToken() async -> Bool {
        // GUI apps have limited PATH — resolve claude binary explicitly
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]

        guard let claudePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["auth", "status"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let success = process.terminationStatus == 0
            return success
        } catch {
            return false
        }
    }

    // MARK: - Fetch Profile

    func fetchProfile() async throws -> UserProfile {
        guard let token = CredentialService.shared.getAccessToken() else {
            throw UsageError.noCredentials
        }

        guard let url = URL(string: profileURL) else {
            throw UsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UsageError.invalidResponse
        }

        return try JSONDecoder().decode(UserProfile.self, from: data)
    }

    var historyStore: UsageHistoryStore? { UsageHistoryStore.shared }

    // MARK: - Cache

    func loadFromCache() -> (data: UsageData, fetchedAt: Date)? {
        return readCacheFile(at: appCacheFilePath())
    }

    func resetLocalState() {
        UserDefaults.standard.removeObject(forKey: "usageAPIRetryAfter")
        try? FileManager.default.removeItem(atPath: appCacheFilePath())
    }

    private func readCacheFile(at path: String) -> (data: UsageData, fetchedAt: Date)? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }

        do {
            let cache = try JSONDecoder().decode(UsageCacheFile.self, from: data)
            guard let timestamp = TimeInterval(cache.fetchedAt) else { return nil }
            let fetchedAt = Date(timeIntervalSince1970: timestamp)
            return (data: cache.data, fetchedAt: fetchedAt)
        } catch {
            return nil
        }
    }

    private func saveToCache(_ usageData: UsageData) {
        let cache = UsageCacheFile(
            fetchedAt: String(Int(Date().timeIntervalSince1970)),
            data: usageData
        )

        do {
            let data = try JSONEncoder().encode(cache)
            let path = appCacheFilePath()
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            // Silently fail cache write
        }
    }

    private func appCacheFilePath() -> String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-statistics")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        return (dir as NSString).appendingPathComponent(cacheFileName)
    }
}

extension UsageAPIService {
    var dashboardURL: URL? {
        URL(string: "https://claude.ai/settings/usage")
    }

    func loadCachedSnapshot() -> ProviderUsageSnapshot? {
        guard let cached = loadFromCache() else { return nil }
        return ProviderUsageSnapshot(data: cached.data, fetchedAt: cached.fetchedAt)
    }

    func refreshSnapshot() async throws -> ProviderUsageSnapshot {
        let data = try await fetchUsage()
        return ProviderUsageSnapshot(data: data, fetchedAt: Date())
    }

    func refreshCredentials() async -> Bool {
        await refreshToken()
    }
}

enum UsageError: LocalizedError {
    case noCredentials
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case rateLimited(retryInSeconds: Int)
    case unauthorized
    case decodingFailed(detail: String, raw: String)

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "No Claude credentials found"
        case .invalidURL: return "Invalid API URL"
        case .invalidResponse: return "Invalid response"
        case .httpError(let code): return "HTTP error: \(code)"
        case .rateLimited(let seconds): return "Rate limited, retry in \(seconds)s"
        case .unauthorized: return "Token expired — open the CLI to refresh"
        case .decodingFailed(let detail, _): return "Decoding error: \(detail)"
        }
    }
}
