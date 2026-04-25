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

    /// Refresh the Claude OAuth token. In Independent mode the app performs the refresh
    /// itself via the Anthropic token endpoint. In Sync mode it delegates to the CLI.
    func refreshToken() async -> Bool {
        switch ClaudeAccountModeController.shared.mode {
        case .independent:
            return await refreshTokenIndependent()
        case .sync:
            return refreshTokenViaCLI()
        }
    }

    private func refreshTokenIndependent() async -> Bool {
        do {
            _ = try await IndependentClaudeCredentialStore.shared.refreshActiveNow()
            CredentialService.shared.invalidate()
            return true
        } catch {
            DiagnosticLogger.shared.warning("Independent token refresh failed: \(error.localizedDescription)")
            return false
        }
    }

    private func refreshTokenViaCLI() -> Bool {
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
            if success {
                CredentialService.shared.invalidate(forceBypassBackup: true)
            }
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
        UserDefaults.standard.removeObject(forKey: AppPreferences.claudeUsageRetryAfter)
        try? FileManager.default.removeItem(atPath: appCacheFilePath())
    }

    private func readCacheFile(at path: String) -> (data: UsageData, fetchedAt: Date)? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }

        do {
            if let cache = try? JSONDecoder().decode(ClaudeUsageCacheFile.self, from: data),
               let timestamp = TimeInterval(cache.fetchedAt) {
                let fetchedAt = Date(timeIntervalSince1970: timestamp)
                return (data: cache.data, fetchedAt: fetchedAt)
            }

            let cache = try JSONDecoder().decode(UsageCacheFile.self, from: data)
            guard let timestamp = TimeInterval(cache.fetchedAt) else { return nil }
            let fetchedAt = Date(timeIntervalSince1970: timestamp)
            return (data: cache.data, fetchedAt: fetchedAt)
        } catch {
            return nil
        }
    }

    private func saveToCache(_ usageData: UsageData) {
        let path = appCacheFilePath()
        let now = String(Int(Date().timeIntervalSince1970))
        let existingCache = readClaudeCacheFile(at: path)
        let fallbackStdin = existingCache.flatMap { legacyStdinSource(from: $0, apiUsage: usageData) }
        let stdinSource = existingCache?.sources?.stdin ?? fallbackStdin
        let apiSource = ClaudeUsageCacheSourceSnapshot(
            fetchedAt: now,
            fiveHour: usageData.fiveHour,
            sevenDay: usageData.sevenDay
        )
        let mergedData = mergeUsageData(apiUsage: usageData, apiSource: apiSource, stdinSource: stdinSource)
        let cache = ClaudeUsageCacheFile(
            fetchedAt: now,
            data: mergedData,
            sources: ClaudeUsageCacheSources(api: apiSource, stdin: stdinSource)
        )

        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            // Silently fail cache write
        }
    }

    private func readClaudeCacheFile(at path: String) -> ClaudeUsageCacheFile? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()

        if let cache = try? decoder.decode(ClaudeUsageCacheFile.self, from: data) {
            return cache
        }

        guard let legacy = try? decoder.decode(UsageCacheFile.self, from: data) else {
            return nil
        }

        return ClaudeUsageCacheFile(
            fetchedAt: legacy.fetchedAt,
            data: legacy.data,
            sources: nil
        )
    }

    private func legacyStdinSource(from cache: ClaudeUsageCacheFile, apiUsage: UsageData) -> ClaudeUsageCacheSourceSnapshot? {
        let inferredFiveHour = inferLegacyWindow(existing: cache.data.fiveHour, api: apiUsage.fiveHour)
        let inferredSevenDay = inferLegacyWindow(existing: cache.data.sevenDay, api: apiUsage.sevenDay)
        guard inferredFiveHour != nil || inferredSevenDay != nil else { return nil }

        return ClaudeUsageCacheSourceSnapshot(
            fetchedAt: cache.fetchedAt,
            fiveHour: inferredFiveHour,
            sevenDay: inferredSevenDay
        )
    }

    private func inferLegacyWindow(existing: UsageWindow?, api: UsageWindow?) -> UsageWindow? {
        guard let existing else { return nil }
        guard let api else { return existing }
        guard sameResetWindow(existing.resetsAt, api.resetsAt), existing.utilization > api.utilization else { return nil }
        return existing
    }

    // API returns resets_at with microsecond precision (e.g. "...:59.957465+00:00"),
    // while Claude Code stdin rounds to integer seconds — the two sources can straddle
    // a minute boundary for the same window. Compare within a 60s tolerance.
    private func sameResetWindow(_ a: String?, _ b: String?) -> Bool {
        if a == b { return true }
        guard let dateA = parseResetsAt(a), let dateB = parseResetsAt(b) else { return false }
        return abs(dateA.timeIntervalSince(dateB)) < 60
    }

    private func parseResetsAt(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func mergeUsageData(
        apiUsage: UsageData,
        apiSource: ClaudeUsageCacheSourceSnapshot?,
        stdinSource: ClaudeUsageCacheSourceSnapshot?
    ) -> UsageData {
        UsageData(
            fiveHour: mergeWindow(
                api: apiSource?.fiveHour,
                apiFetchedAt: apiSource?.fetchedAt,
                stdin: stdinSource?.fiveHour,
                stdinFetchedAt: stdinSource?.fetchedAt
            ),
            sevenDay: mergeWindow(
                api: apiSource?.sevenDay,
                apiFetchedAt: apiSource?.fetchedAt,
                stdin: stdinSource?.sevenDay,
                stdinFetchedAt: stdinSource?.fetchedAt
            ),
            sevenDayOauthApps: apiUsage.sevenDayOauthApps,
            sevenDayOpus: apiUsage.sevenDayOpus,
            sevenDaySonnet: apiUsage.sevenDaySonnet,
            sevenDayCowork: apiUsage.sevenDayCowork,
            providerBuckets: apiUsage.providerBuckets,
            extraUsage: apiUsage.extraUsage
        )
    }

    private func mergeWindow(
        api: UsageWindow?,
        apiFetchedAt: String?,
        stdin: UsageWindow?,
        stdinFetchedAt: String?
    ) -> UsageWindow? {
        switch (api, stdin) {
        case (nil, nil):
            return nil
        case let (api?, nil):
            return api
        case let (nil, stdin?):
            return stdin
        case let (api?, stdin?):
            if sameResetWindow(api.resetsAt, stdin.resetsAt) {
                return UsageWindow(
                    utilization: max(api.utilization, stdin.utilization),
                    resetsAt: api.resetsAt ?? stdin.resetsAt
                )
            }

            let apiTimestamp = TimeInterval(apiFetchedAt ?? "") ?? 0
            let stdinTimestamp = TimeInterval(stdinFetchedAt ?? "") ?? 0
            return stdinTimestamp >= apiTimestamp ? stdin : api
        }
    }

    private func appCacheFilePath() -> String {
        let dir = AppRuntimePaths.ensureRootDirectory() ?? AppRuntimePaths.rootDirectory
        return (dir as NSString).appendingPathComponent(cacheFileName)
    }
}

extension UsageAPIService {
    var dashboardURL: URL? {
        URL(string: "https://claude.ai/settings/usage")
    }

    var usageCacheFilePath: String? {
        appCacheFilePath()
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
