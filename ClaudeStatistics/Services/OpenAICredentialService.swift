import Foundation

struct OpenAIAuthState: Codable, Equatable {
    let configured: Bool
    let accountId: String?
    let accountEmail: String?
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
}

final class OpenAICredentialService {
    static let shared = OpenAICredentialService()

    private init() {}

    func loadAuthState() -> OpenAIAuthState? {
        loadAuthState(from: authFileURL())
    }

    func loadAuthState(from url: URL) -> OpenAIAuthState? {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return nil
        }
        return Self.decodeAuthState(from: data, now: Date())
    }

    static func decodeAuthState(from data: Data, now: Date) -> OpenAIAuthState? {
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

        guard let payload = try? decoder.decode(OpenAIAuthFile.self, from: data) else {
            return nil
        }
        guard payload.authMode == "chatgpt" else {
            return nil
        }
        guard let accessToken = payload.tokens?.accessToken, !accessToken.isEmpty else {
            return nil
        }

        return OpenAIAuthState(
            configured: true,
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
