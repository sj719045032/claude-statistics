import Foundation

protocol OpenAIUsageServicing: AnyObject {
    var authState: OpenAIAuthState { get }

    func loadCache() -> (data: OpenAIUsageData, fetchedAt: Date)?
    func fetchUsage() async throws -> OpenAIUsageData
}

final class OpenAIUsageAPIService: OpenAIUsageServicing {
    static let shared = OpenAIUsageAPIService()

    private let credentialService: OpenAICredentialService
    private let session: URLSession
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")
    private let refreshURL = URL(string: "https://auth.openai.com/oauth/token")
    private let cacheFileName = "openai-usage-cache.json"

    private init(
        credentialService: OpenAICredentialService = .shared,
        session: URLSession = .shared
    ) {
        self.credentialService = credentialService
        self.session = session
    }

    var authState: OpenAIAuthState {
        credentialService.loadAuthState()
    }

    func loadCache() -> (data: OpenAIUsageData, fetchedAt: Date)? {
        let url = cacheFileURL()
        guard let rawData = FileManager.default.contents(atPath: url.path) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(OpenAIUsageCacheFile.self, from: rawData) else {
            return nil
        }

        return (cache.data, cache.fetchedAt)
    }

    func fetchUsage() async throws -> OpenAIUsageData {
        let state = credentialService.loadAuthState()
        guard state.isConfigured, let accessToken = state.accessToken else {
            throw OpenAIUsageError.notConfigured(state.status)
        }

        return try await fetchUsage(
            accessToken: accessToken,
            refreshToken: state.refreshToken,
            accountId: state.accountId,
            accountEmail: state.accountEmail,
            canRefresh: true
        )
    }

    private func fetchUsage(
        accessToken: String,
        refreshToken: String?,
        accountId: String?,
        accountEmail: String?,
        canRefresh: Bool
    ) async throws -> OpenAIUsageData {
        do {
            return try await performUsageFetch(
                accessToken: accessToken,
                accountId: accountId,
                accountEmail: accountEmail
            )
        } catch let error as OpenAIUsageError {
            guard error.isUnauthorized, canRefresh, let refreshToken else {
                throw error
            }

            let refreshed = try await refreshAccessToken(refreshToken: refreshToken)
            try credentialService.persistRefreshedTokens(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                idToken: refreshed.idToken
            )

            let updatedState = credentialService.loadAuthState()
            guard updatedState.isConfigured, let updatedAccessToken = updatedState.accessToken else {
                throw OpenAIUsageError.refreshFailed("Refreshed auth could not be reloaded")
            }

            return try await fetchUsage(
                accessToken: updatedAccessToken,
                refreshToken: updatedState.refreshToken,
                accountId: updatedState.accountId,
                accountEmail: updatedState.accountEmail,
                canRefresh: false
            )
        }
    }

    private func performUsageFetch(
        accessToken: String,
        accountId: String?,
        accountEmail: String?
    ) async throws -> OpenAIUsageData {
        guard let usageURL else {
            throw OpenAIUsageError.invalidURL
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIUsageError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw OpenAIUsageError.unauthorized(statusCode: httpResponse.statusCode, body: rawBody(from: data))
        }

        guard httpResponse.statusCode == 200 else {
            throw OpenAIUsageError.httpError(statusCode: httpResponse.statusCode, body: rawBody(from: data))
        }

        guard let usage = OpenAIUsageData.decodeUsageResponse(from: data, accountEmail: accountEmail) else {
            throw OpenAIUsageError.decodingFailed(
                detail: "Unable to decode OpenAI usage payload",
                raw: rawBody(from: data)
            )
        }

        saveToCache(usage)
        return usage
    }

    private func refreshAccessToken(refreshToken: String) async throws -> OpenAIRefreshResponse {
        guard let refreshURL else {
            throw OpenAIUsageError.invalidURL
        }

        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIUsageError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw OpenAIUsageError.refreshFailed(
                "HTTP \(httpResponse.statusCode): \(rawBody(from: data))"
            )
        }

        do {
            return try JSONDecoder().decode(OpenAIRefreshResponse.self, from: data)
        } catch {
            throw OpenAIUsageError.refreshFailed(
                "Decoding error: \(error.localizedDescription)"
            )
        }
    }

    private func saveToCache(_ usageData: OpenAIUsageData) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let cache = OpenAIUsageCacheFile(fetchedAt: Date(), data: usageData)

        do {
            let data = try encoder.encode(cache)
            let url = cacheFileURL()
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache failures are non-fatal.
        }
    }

    private func cacheFileURL() -> URL {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude-statistics", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        return directory.appendingPathComponent(cacheFileName)
    }

    private func rawBody(from data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "<binary>"
    }
}

private struct OpenAIRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
    }
}

enum OpenAIUsageError: LocalizedError {
    case notConfigured(OpenAIAuthStatus)
    case invalidURL
    case invalidResponse
    case unauthorized(statusCode: Int, body: String?)
    case httpError(statusCode: Int, body: String?)
    case decodingFailed(detail: String, raw: String)
    case refreshFailed(String)

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured(let status):
            switch status {
            case .notFound:
                return "OpenAI auth file not found"
            case .unsupportedMode:
                return "OpenAI auth uses an unsupported mode"
            case .invalidAuth:
                return "OpenAI auth payload is invalid"
            case .configured:
                return "OpenAI is configured"
            }
        case .invalidURL:
            return "Invalid OpenAI usage URL"
        case .invalidResponse:
            return "Invalid OpenAI response"
        case .unauthorized(let code, let body):
            return body?.isEmpty == false ? "Unauthorized (\(code)): \(body!)" : "Unauthorized (\(code))"
        case .httpError(let code, let body):
            return body?.isEmpty == false ? "HTTP \(code): \(body!)" : "HTTP \(code)"
        case .decodingFailed(let detail, let raw):
            return "\(detail). Raw: \(raw)"
        case .refreshFailed(let detail):
            return "Token refresh failed: \(detail)"
        }
    }
}
