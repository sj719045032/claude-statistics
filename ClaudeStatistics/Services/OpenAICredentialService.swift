import Foundation

enum OpenAIAuthStatus: String, Codable, Equatable {
    case configured
    case notFound
    case unsupportedMode
    case invalidAuth

    var description: String {
        switch self {
        case .configured:
            return "configured"
        case .notFound:
            return "not found"
        case .unsupportedMode:
            return "unsupported auth mode"
        case .invalidAuth:
            return "invalid auth"
        }
    }
}

struct OpenAIAuthState: Equatable {
    let status: OpenAIAuthStatus
    let accountId: String?
    let accountEmail: String?
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?

    var isConfigured: Bool {
        status == .configured
    }
}

final class OpenAICredentialService {
    static let shared = OpenAICredentialService()

    private init() {}

    func loadAuthState() -> OpenAIAuthState {
        loadAuthState(from: authFileURL())
    }

    func loadAuthState(from url: URL) -> OpenAIAuthState {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = FileManager.default.contents(atPath: url.path) else {
            return OpenAIAuthState(
                status: .notFound,
                accountId: nil,
                accountEmail: nil,
                accessToken: nil,
                refreshToken: nil,
                idToken: nil
            )
        }
        return Self.decodeAuthState(from: data, now: Date())
    }

    func persistRefreshedTokens(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        now: Date = Date()
    ) throws {
        let url = authFileURL()
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw OpenAICredentialError.missingAuthFile
        }

        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAICredentialError.invalidAuthFile
        }

        var tokens = json["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = accessToken
        if let refreshToken {
            tokens["refresh_token"] = refreshToken
        }
        if let idToken {
            tokens["id_token"] = idToken
        }

        json["tokens"] = tokens
        json["last_refresh"] = Self.iso8601String(from: now)

        let output = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .prettyPrinted])
        try output.write(to: url, options: .atomic)
    }

    static func decodeAuthState(from data: Data, now: Date) -> OpenAIAuthState {
        let decoder = JSONDecoder()

        guard let payload = try? decoder.decode(OpenAIAuthFile.self, from: data) else {
            return OpenAIAuthState(
                status: .invalidAuth,
                accountId: nil,
                accountEmail: nil,
                accessToken: nil,
                refreshToken: nil,
                idToken: nil
            )
        }
        guard payload.authMode == "chatgpt" else {
            return OpenAIAuthState(
                status: .unsupportedMode,
                accountId: payload.tokens?.accountId,
                accountEmail: payload.tokens?.decodedEmail,
                accessToken: payload.tokens?.accessToken,
                refreshToken: payload.tokens?.refreshToken,
                idToken: payload.tokens?.idToken
            )
        }
        guard let accessToken = payload.tokens?.accessToken, !accessToken.isEmpty else {
            return OpenAIAuthState(
                status: .invalidAuth,
                accountId: payload.tokens?.accountId,
                accountEmail: payload.tokens?.decodedEmail,
                accessToken: nil,
                refreshToken: payload.tokens?.refreshToken,
                idToken: payload.tokens?.idToken
            )
        }

        return OpenAIAuthState(
            status: .configured,
            accountId: payload.tokens?.accountId,
            accountEmail: payload.tokens?.decodedEmail,
            accessToken: accessToken,
            refreshToken: payload.tokens?.refreshToken,
            idToken: payload.tokens?.idToken
        )
    }

    private func authFileURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct OpenAIAuthFile: Codable {
    let authMode: String
    let tokens: OpenAIAuthTokens?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
    }
}

private struct OpenAIAuthTokens: Codable {
    let accessToken: String?
    let refreshToken: String?
    let idToken: String?
    let accountId: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountId = "account_id"
    }

    var decodedEmail: String? {
        guard let idToken else { return nil }
        return OpenAICredentialService.decodeEmail(fromJWT: idToken)
    }
}

private extension OpenAICredentialService {
    static func decodeEmail(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let payload = base64URLDecodedData(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }

        let candidates = [
            json["email"] as? String,
            json["preferred_username"] as? String,
            json["upn"] as? String,
            json["unique_name"] as? String
        ]

        return candidates.compactMap { $0 }.first
    }

    static func base64URLDecodedData(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }

        return Data(base64Encoded: base64)
    }
}

enum OpenAICredentialError: LocalizedError {
    case missingAuthFile
    case invalidAuthFile

    var errorDescription: String? {
        switch self {
        case .missingAuthFile:
            return "OpenAI auth file not found"
        case .invalidAuthFile:
            return "OpenAI auth file is invalid"
        }
    }
}
