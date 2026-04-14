import Foundation

final class GeminiUsageService: ProviderUsageSource {
    static let shared = GeminiUsageService()

    private let settingsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/settings.json")
    private let oauthCredsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/oauth_creds.json")
    private let googleAccountsPath = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/google_accounts.json")
    private let cacheFileName = "gemini-usage-cache.json"
    private let oauthTokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private init() {}

    var dashboardURL: URL? { URL(string: "https://aistudio.google.com/app/quotas") }

    var hasUsableCredentials: Bool {
        guard let settings = try? readSettings() else { return false }
        switch settings.selectedAuthType {
        case .oauthPersonal:
            return (try? readOAuthCredentials()) != nil
        case .geminiAPIKey, .vertexAI:
            return true
        case .unknown:
            return false
        }
    }

    func loadCachedSnapshot() -> ProviderUsageSnapshot? {
        guard let data = FileManager.default.contents(atPath: cacheFilePath()),
              let cache = try? JSONDecoder().decode(UsageCacheFile.self, from: data),
              let timestamp = TimeInterval(cache.fetchedAt) else {
            return nil
        }
        return ProviderUsageSnapshot(
            data: normalizedUsageData(cache.data),
            fetchedAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    func refreshSnapshot() async throws -> ProviderUsageSnapshot {
        let settings = try readSettings()

        let usageData: UsageData
        switch settings.selectedAuthType {
        case .oauthPersonal:
            let context = try await loadQuotaContext(settings: settings)
            let buckets = buildBuckets(from: context.quota.buckets ?? [], activeModel: settings.modelName)
            guard !buckets.isEmpty else {
                throw UsageError.invalidResponse
            }
            usageData = makeUsageData(with: buckets)
        case .geminiAPIKey:
            usageData = makeUsageData(with: [localDailyBucket(id: "gemini-api-key", title: "API Key", dailyLimit: 250)])
        case .vertexAI:
            throw UsageError.invalidResponse
        case .unknown:
            throw UsageError.noCredentials
        }

        saveToCache(usageData)
        return ProviderUsageSnapshot(data: usageData, fetchedAt: Date())
    }

    func refreshCredentials() async -> Bool {
        guard let settings = try? readSettings(),
              settings.selectedAuthType == .oauthPersonal,
              let credentials = try? readOAuthCredentials(),
              !credentials.refreshToken.isEmpty else {
            return false
        }

        do {
            let refreshed = try await refreshOAuthCredentials(credentials)
            try saveOAuthCredentials(refreshed)
            return true
        } catch {
            return false
        }
    }

    func fetchProfile() async -> UserProfile? {
        guard let settings = try? readSettings() else { return nil }

        let credentials = try? readOAuthCredentials()
        let claims = credentials?.idToken.flatMap(decodeJWTClaims)
        let activeEmail = readActiveAccountEmail()

        var tierName: String?
        if settings.selectedAuthType == .oauthPersonal,
           let context = try? await loadQuotaContext(settings: settings) {
            tierName = context.tierName
        }

        let email = (claims?["email"] as? String) ?? activeEmail
        let name = claims?["name"] as? String
        let displayName = name ?? email?.components(separatedBy: "@").first

        return UserProfile(
            account: ProfileAccount(
                fullName: name,
                displayName: displayName,
                email: email,
                hasMaxPlan: nil,
                hasProPlan: nil
            ),
            organization: ProfileOrganization(
                name: nil,
                organizationType: settings.selectedAuthType.displayName,
                rateLimitTier: tierName ?? inferredTierName(from: settings),
                subscriptionStatus: hasUsableCredentials ? "active" : nil
            )
        )
    }

    private func loadQuotaContext(settings: GeminiSettings) async throws -> GeminiQuotaContext {
        var credentials = try readOAuthCredentials()
        if credentials.isExpired {
            credentials = try await refreshOAuthCredentials(credentials)
            try saveOAuthCredentials(credentials)
        }

        let load = try await loadCodeAssist(credentials: credentials)
        let projectId = load.cloudaicompanionProject
        guard let projectId, !projectId.isEmpty else {
            throw UsageError.invalidResponse
        }

        let quota = try await retrieveUserQuota(credentials: credentials, projectId: projectId)
        return GeminiQuotaContext(
            quota: quota,
            tierName: load.paidTier?.name ?? load.currentTier?.name
        )
    }

    private func loadCodeAssist(credentials: GeminiOAuthCredentials) async throws -> GeminiLoadCodeAssistResponse {
        let body = GeminiLoadCodeAssistRequest(
            cloudaicompanionProject: ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"],
            metadata: .init(
                ideType: "IDE_UNSPECIFIED",
                platform: "PLATFORM_UNSPECIFIED",
                pluginType: "GEMINI",
                duetProject: ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ?? ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]
            )
        )
        return try await postJSON(
            method: "loadCodeAssist",
            credentials: credentials,
            body: body,
            responseType: GeminiLoadCodeAssistResponse.self
        )
    }

    private func retrieveUserQuota(credentials: GeminiOAuthCredentials, projectId: String) async throws -> GeminiQuotaResponse {
        try await postJSON(
            method: "retrieveUserQuota",
            credentials: credentials,
            body: GeminiQuotaRequest(project: projectId),
            responseType: GeminiQuotaResponse.self
        )
    }

    private func postJSON<Body: Encodable, Response: Decodable>(
        method: String,
        credentials: GeminiOAuthCredentials,
        body: Body,
        responseType: Response.Type
    ) async throws -> Response {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:\(method)") else {
            throw UsageError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("ClaudeStatistics", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(responseType, from: data)
        case 401, 403:
            throw UsageError.unauthorized
        case 429:
            let retrySeconds = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init) ?? 60
            throw UsageError.rateLimited(retryInSeconds: retrySeconds)
        default:
            throw UsageError.httpError(statusCode: http.statusCode)
        }
    }

    private func refreshOAuthCredentials(_ credentials: GeminiOAuthCredentials) async throws -> GeminiOAuthCredentials {
        guard let oauthClientID = oauthClientID(from: credentials) else {
            throw UsageError.unauthorized
        }

        var request = URLRequest(url: oauthTokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": oauthClientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
        ]
        request.httpBody = formEncoded(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw UsageError.unauthorized
            }
            throw UsageError.httpError(statusCode: http.statusCode)
        }

        let refreshed = try JSONDecoder().decode(GeminiOAuthRefreshResponse.self, from: data)
        let expiryDate = Date().addingTimeInterval(TimeInterval(refreshed.expiresIn)).timeIntervalSince1970 * 1000
        return GeminiOAuthCredentials(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? credentials.refreshToken,
            idToken: refreshed.idToken ?? credentials.idToken,
            expiryDate: expiryDate,
            tokenType: refreshed.tokenType ?? credentials.tokenType
        )
    }

    private func buildBuckets(from buckets: [GeminiQuotaBucket], activeModel: String?) -> [ProviderUsageBucket] {
        let activeFamily = activeModel.flatMap(modelFamily(for:))

        let rawBuckets = buckets.compactMap { bucket -> (id: String, family: String, title: String, percent: Double, reset: String?, remaining: Double?, limit: Double?, unit: String?)? in
            guard let modelId = bucket.modelId,
                  let remainingFraction = bucket.remainingFraction else {
                return nil
            }

            let family = modelFamily(for: modelId)
            let remaining = bucket.remainingAmount
            let limit = bucket.limitAmount ?? bucket.inferredLimitAmount
            return (
                id: modelId,
                family: family,
                title: displayTitle(forFamily: family, fallbackModelId: modelId),
                percent: remainingFraction * 100,
                reset: bucket.resetTime,
                remaining: remaining,
                limit: limit,
                unit: bucket.effectiveUnit
            )
        }

        var grouped: [String: (id: String, title: String, percent: Double, reset: String?, remaining: Double?, limit: Double?, unit: String?)] = [:]
        for bucket in rawBuckets {
            if let existing = grouped[bucket.family] {
                let useIncomingLimit = bucket.percent < existing.percent
                grouped[bucket.family] = (
                    id: preferredBucketId(existing.id, bucket.id, activeFamily: activeFamily),
                    title: existing.title,
                    percent: min(existing.percent, bucket.percent),
                    reset: latestReset(existing.reset, bucket.reset),
                    remaining: useIncomingLimit ? bucket.remaining : existing.remaining,
                    limit: useIncomingLimit ? bucket.limit : existing.limit,
                    unit: useIncomingLimit ? bucket.unit : existing.unit
                )
            } else {
                grouped[bucket.family] = (
                    id: bucket.id,
                    title: bucket.title,
                    percent: bucket.percent,
                    reset: bucket.reset,
                    remaining: bucket.remaining,
                    limit: bucket.limit,
                    unit: bucket.unit
                )
            }
        }

        return groupProviderBuckets(grouped.values.map { bucket in
            ProviderUsageBucket(
                id: bucket.id,
                title: bucket.title,
                subtitle: quotaSubtitle(remaining: bucket.remaining, limit: bucket.limit, unit: bucket.unit),
                remainingPercentage: bucket.percent,
                resetsAt: bucket.reset,
                remainingAmount: bucket.remaining,
                limitAmount: bucket.limit,
                unit: bucket.unit
            )
        }, activeFamily: activeFamily)
    }

    private func normalizedUsageData(_ data: UsageData) -> UsageData {
        guard let buckets = data.providerBuckets else { return data }
        return UsageData(
            fiveHour: data.fiveHour,
            sevenDay: data.sevenDay,
            sevenDayOauthApps: data.sevenDayOauthApps,
            sevenDayOpus: data.sevenDayOpus,
            sevenDaySonnet: data.sevenDaySonnet,
            sevenDayCowork: data.sevenDayCowork,
            providerBuckets: groupProviderBuckets(buckets, activeFamily: nil),
            extraUsage: data.extraUsage
        )
    }

    private func groupProviderBuckets(_ buckets: [ProviderUsageBucket], activeFamily: String?) -> [ProviderUsageBucket] {
        var grouped: [String: ProviderUsageBucket] = [:]

        for bucket in buckets {
            let family = modelFamily(for: bucket.id)
            let title = displayTitle(forFamily: family, fallbackModelId: bucket.id)

            if let existing = grouped[family] {
                grouped[family] = ProviderUsageBucket(
                    id: preferredBucketId(existing.id, bucket.id, activeFamily: activeFamily),
                    title: title,
                    subtitle: bucket.remainingPercentage < existing.remainingPercentage ? bucket.subtitle : existing.subtitle,
                    remainingPercentage: min(existing.remainingPercentage, bucket.remainingPercentage),
                    resetsAt: latestReset(existing.resetsAt, bucket.resetsAt),
                    remainingAmount: bucket.remainingPercentage < existing.remainingPercentage ? bucket.remainingAmount : existing.remainingAmount,
                    limitAmount: bucket.remainingPercentage < existing.remainingPercentage ? bucket.limitAmount : existing.limitAmount,
                    unit: bucket.remainingPercentage < existing.remainingPercentage ? bucket.unit : existing.unit
                )
            } else {
                grouped[family] = ProviderUsageBucket(
                    id: bucket.id,
                    title: title,
                    subtitle: bucket.subtitle,
                    remainingPercentage: bucket.remainingPercentage,
                    resetsAt: bucket.resetsAt,
                    remainingAmount: bucket.remainingAmount,
                    limitAmount: bucket.limitAmount,
                    unit: bucket.unit
                )
            }
        }

        return grouped.values.sorted { lhs, rhs in
            let lhsFamily = modelFamily(for: lhs.id)
            let rhsFamily = modelFamily(for: rhs.id)
            let lhsActive = lhsFamily == activeFamily
            let rhsActive = rhsFamily == activeFamily
            if lhsActive != rhsActive {
                return lhsActive && !rhsActive
            }
            return bucketSortRank(for: lhs.id) < bucketSortRank(for: rhs.id)
        }
    }

    private func makeUsageData(with buckets: [ProviderUsageBucket]) -> UsageData {
        UsageData(
            fiveHour: nil,
            sevenDay: nil,
            sevenDayOauthApps: nil,
            sevenDayOpus: nil,
            sevenDaySonnet: nil,
            sevenDayCowork: nil,
            providerBuckets: buckets,
            extraUsage: nil
        )
    }

    private func localDailyBucket(id: String, title: String, dailyLimit: Int) -> ProviderUsageBucket {
        let todayCount = localUserRequestCount(since: Calendar.current.startOfDay(for: Date()))
        let remaining = max(0, dailyLimit - todayCount)
        let remainingPercentage = dailyLimit > 0 ? (Double(remaining) / Double(dailyLimit)) * 100 : 0
        return ProviderUsageBucket(
            id: id,
            title: title,
            subtitle: quotaSubtitle(remaining: Double(remaining), limit: Double(dailyLimit), unit: "requests"),
            remainingPercentage: remainingPercentage,
            resetsAt: isoString(for: nextLocalMidnight()),
            remainingAmount: Double(remaining),
            limitAmount: Double(dailyLimit),
            unit: "requests"
        )
    }

    private func localUserRequestCount(since start: Date) -> Int {
        let tmpDirectory = (NSHomeDirectory() as NSString).appendingPathComponent(".gemini/tmp")
        guard let enumerator = FileManager.default.enumerator(atPath: tmpDirectory) else { return 0 }

        var count = 0
        for case let path as String in enumerator where path.hasSuffix("/logs.json") {
            let fullPath = (tmpDirectory as NSString).appendingPathComponent(path)
            guard let data = FileManager.default.contents(atPath: fullPath),
                  let entries = try? JSONDecoder().decode([GeminiLogEntry].self, from: data) else {
                continue
            }

            count += entries.filter { entry in
                entry.type == "user" &&
                    !(entry.message ?? "").hasPrefix("/") &&
                    (entry.timestampDate ?? .distantPast) >= start
            }.count
        }
        return count
    }

    private func nextLocalMidnight() -> Date {
        Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(24 * 3600)
    }

    private func isoString(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func displayTitle(forFamily family: String, fallbackModelId: String) -> String {
        switch family {
        case "pro": return "Pro"
        case "flash": return "Flash"
        case "flash-lite": return "Flash Lite"
        default:
            return fallbackModelId
                .replacingOccurrences(of: "gemini-", with: "")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
    }

    private func preferredBucketId(_ lhs: String, _ rhs: String, activeFamily: String?) -> String {
        let lhsFamily = modelFamily(for: lhs)
        let rhsFamily = modelFamily(for: rhs)
        if let activeFamily {
            if lhsFamily == activeFamily && rhsFamily != activeFamily { return lhs }
            if rhsFamily == activeFamily && lhsFamily != activeFamily { return rhs }
        }

        if lhs.contains("3.1") && !rhs.contains("3.1") { return lhs }
        if rhs.contains("3.1") && !lhs.contains("3.1") { return rhs }
        return lhs
    }

    private func latestReset(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return rhs > lhs ? rhs : lhs
    }

    private func modelFamily(for modelId: String) -> String {
        let lower = modelId.lowercased()
        if lower.contains("flash-lite") { return "flash-lite" }
        if lower.contains("flash") { return "flash" }
        if lower.contains("pro") { return "pro" }
        return lower
    }

    private func bucketSortRank(for modelId: String) -> Int {
        switch modelFamily(for: modelId) {
        case "pro": return 0
        case "flash": return 1
        case "flash-lite": return 2
        default: return 9
        }
    }

    private func quotaSubtitle(remaining: Double?, limit: Double?, unit: String?) -> String? {
        guard let remaining else { return unit }

        let amount = formatQuotaAmount(remaining)
        if let limit {
            let limitText = formatQuotaAmount(limit)
            if let unit, !unit.isEmpty {
                return "\(amount)/\(limitText) \(unit)"
            }
            return "\(amount)/\(limitText)"
        }

        if let unit, !unit.isEmpty {
            return "\(amount) \(unit)"
        }
        return amount
    }

    private func formatQuotaAmount(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.001 {
            return Int(rounded).formatted()
        }
        return String(format: "%.1f", value)
    }

    private func inferredTierName(from settings: GeminiSettings) -> String? {
        switch settings.selectedAuthType {
        case .oauthPersonal:
            return "Free"
        case .geminiAPIKey:
            return "Gemini API Key"
        case .vertexAI:
            return "Vertex AI"
        case .unknown:
            return nil
        }
    }

    private func readSettings() throws -> GeminiSettings {
        guard let data = FileManager.default.contents(atPath: settingsPath) else {
            throw UsageError.noCredentials
        }
        return try JSONDecoder().decode(GeminiSettings.self, from: data)
    }

    private func readOAuthCredentials() throws -> GeminiOAuthCredentials {
        guard let data = FileManager.default.contents(atPath: oauthCredsPath) else {
            throw UsageError.noCredentials
        }
        return try JSONDecoder().decode(GeminiOAuthCredentials.self, from: data)
    }

    private func saveOAuthCredentials(_ credentials: GeminiOAuthCredentials) throws {
        let data: Data
        if let existing = FileManager.default.contents(atPath: oauthCredsPath),
           var json = try JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            json["access_token"] = credentials.accessToken
            json["refresh_token"] = credentials.refreshToken
            if let idToken = credentials.idToken {
                json["id_token"] = idToken
            }
            if let expiryDate = credentials.expiryDate {
                json["expiry_date"] = expiryDate
            }
            if let tokenType = credentials.tokenType {
                json["token_type"] = tokenType
            }
            data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } else {
            data = try JSONEncoder().encode(credentials)
        }
        try data.write(to: URL(fileURLWithPath: oauthCredsPath), options: .atomic)
    }

    private func readActiveAccountEmail() -> String? {
        guard let data = FileManager.default.contents(atPath: googleAccountsPath),
              let accounts = try? JSONDecoder().decode(GoogleAccounts.self, from: data) else {
            return nil
        }
        return accounts.active
    }

    private func saveToCache(_ usageData: UsageData) {
        let cache = UsageCacheFile(
            fetchedAt: String(Int(Date().timeIntervalSince1970)),
            data: usageData
        )
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

    private func oauthClientID(from credentials: GeminiOAuthCredentials) -> String? {
        guard let idToken = credentials.idToken,
              let claims = decodeJWTClaims(idToken) else {
            return nil
        }
        return (claims["aud"] as? String) ?? (claims["azp"] as? String)
    }

    private func decodeJWTClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func formEncoded(_ values: [String: String]) -> String {
        values
            .map { key, value in
                let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
                let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(escapedKey)=\(escapedValue)"
            }
            .sorted()
            .joined(separator: "&")
    }
}

private struct GeminiQuotaContext {
    let quota: GeminiQuotaResponse
    let tierName: String?
}

private struct GeminiSettings: Decodable {
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

private enum GeminiAuthType: String {
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

private struct GeminiOAuthCredentials: Codable {
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

private struct GeminiOAuthRefreshResponse: Decodable {
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

private struct GoogleAccounts: Decodable {
    let active: String?
}

private struct GeminiLoadCodeAssistRequest: Encodable {
    let cloudaicompanionProject: String?
    let metadata: Metadata

    struct Metadata: Encodable {
        let ideType: String
        let platform: String
        let pluginType: String
        let duetProject: String?
    }
}

private struct GeminiQuotaRequest: Encodable {
    let project: String
}

private struct GeminiLoadCodeAssistResponse: Decodable {
    let currentTier: GeminiTier?
    let paidTier: GeminiTier?
    let cloudaicompanionProject: String?
}

private struct GeminiTier: Decodable {
    let id: String?
    let name: String?
}

private struct GeminiQuotaResponse: Decodable {
    let buckets: [GeminiQuotaBucket]?
}

private struct GeminiQuotaBucket: Decodable {
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

private struct GeminiLogEntry: Decodable {
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
