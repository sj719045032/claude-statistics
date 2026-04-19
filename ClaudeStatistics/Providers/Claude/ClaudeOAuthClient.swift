import Foundation

enum ClaudeOAuthConfig {
    static let authURL = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenURL = URL(string: "https://api.anthropic.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let redirectURI = "http://localhost:54545/callback"
    /// Stats-only app: only needs profile + usage read.
    /// `user:inference` / `user:file_upload` / `user:mcp_servers` / `user:sessions:claude_code`
    /// are intentionally omitted so the authorize consent screen shows just one checkmark.
    static let scopes = "user:profile"
    static let userAgent = "claude-code/2.1"
    static let callbackPort: UInt16 = 54545
}

/// OAuth tokens plus account metadata returned by the Anthropic token endpoint.
struct ClaudeOAuthTokenBundle {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scopes: [String]
    let accountUUID: String?
    let emailAddress: String?
    let organizationUUID: String?
    let subscriptionType: String?
    let rateLimitTier: String?

    /// JSON matching the `{ claudeAiOauth: { ... } }` shape used by the CLI's credential file.
    /// We reuse this format so downstream parsing code works unchanged.
    func makeRawJSONString() -> String {
        var oauth: [String: Any] = [
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "expiresAt": Int(expiresAt.timeIntervalSince1970 * 1000),
            "scopes": scopes,
        ]
        if let subscriptionType { oauth["subscriptionType"] = subscriptionType }
        if let rateLimitTier { oauth["rateLimitTier"] = rateLimitTier }

        var account: [String: Any] = [:]
        if let accountUUID { account["accountUuid"] = accountUUID }
        if let emailAddress { account["email"] = emailAddress }
        if let organizationUUID { account["organizationUuid"] = organizationUUID }
        if !account.isEmpty {
            oauth["account"] = account
        }

        let wrapper: [String: Any] = ["claudeAiOauth": oauth]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

enum ClaudeOAuthError: LocalizedError {
    case stateMismatch
    case exchangeFailed(status: Int, body: String)
    case refreshFailed(status: Int, body: String)
    case network(Error)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .stateMismatch:
            return "OAuth state mismatch — the callback does not match the original request."
        case let .exchangeFailed(status, body):
            return "Code exchange failed (HTTP \(status)): \(body)"
        case let .refreshFailed(status, body):
            return "Token refresh failed (HTTP \(status)): \(body)"
        case let .network(error):
            return "Network error: \(error.localizedDescription)"
        case let .invalidResponse(detail):
            return "Invalid OAuth response: \(detail)"
        }
    }
}

/// Stateless HTTP helper for the Claude OAuth endpoint.
/// Uses URLSession; if Cloudflare TLS fingerprinting blocks requests we'd add a curl-based fallback here.
final class ClaudeOAuthClient {
    static let shared = ClaudeOAuthClient()
    private init() {}

    func buildAuthorizationURL(state: String, pkce: ClaudePKCE) -> URL {
        // Alphabetical order — matches Go's `url.Values.Encode()` output used by
        // CLIProxyAPI, which is what Anthropic's authorize endpoint is known to accept.
        let pairs: [(String, String)] = [
            ("client_id", ClaudeOAuthConfig.clientID),
            ("code", "true"),
            ("code_challenge", pkce.codeChallenge),
            ("code_challenge_method", "S256"),
            ("redirect_uri", ClaudeOAuthConfig.redirectURI),
            ("response_type", "code"),
            ("scope", ClaudeOAuthConfig.scopes),
            ("state", state),
        ]
        let query = Self.formURLEncode(pairs)
        return URL(string: ClaudeOAuthConfig.authURL.absoluteString + "?" + query)!
    }

    /// Percent-encodes query pairs using the same rules as Go's `url.Values.Encode()`
    /// so that reserved characters in `redirect_uri` (`/` and `:`) get escaped.
    /// Anthropic's OAuth endpoint rejects requests whose `redirect_uri` is not fully encoded.
    private static func formURLEncode(_ pairs: [(String, String)]) -> String {
        // RFC 3986 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~"
        // Space is encoded as "+" (application/x-www-form-urlencoded style)
        // to match Go's url.Values.Encode(). Anthropic's endpoint is picky
        // and rejects scope values whose spaces are %20-encoded.
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        func encode(_ s: String) -> String {
            (s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s)
                .replacingOccurrences(of: "%20", with: "+")
        }
        return pairs.map { key, value in "\(encode(key))=\(encode(value))" }.joined(separator: "&")
    }

    /// Exchanges an authorization code for tokens. The code sometimes arrives with a
    /// `#state` suffix (matches CLIProxyAPI's observation); we split it here.
    func exchangeCode(code rawCode: String, state expectedState: String, pkce: ClaudePKCE) async throws -> ClaudeOAuthTokenBundle {
        let parts = rawCode.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts[0])
        let state = parts.count > 1 ? String(parts[1]) : expectedState

        let body: [String: Any] = [
            "code": code,
            "state": state,
            "grant_type": "authorization_code",
            "client_id": ClaudeOAuthConfig.clientID,
            "redirect_uri": ClaudeOAuthConfig.redirectURI,
            "code_verifier": pkce.codeVerifier,
        ]
        return try await performTokenRequest(body: body, kind: .exchange)
    }

    func refreshToken(_ refreshToken: String) async throws -> ClaudeOAuthTokenBundle {
        let body: [String: Any] = [
            "client_id": ClaudeOAuthConfig.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        return try await performTokenRequest(body: body, kind: .refresh)
    }

    // MARK: - Internals

    private enum RequestKind {
        case exchange, refresh
    }

    private func performTokenRequest(body: [String: Any], kind: RequestKind) async throws -> ClaudeOAuthTokenBundle {
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw ClaudeOAuthError.invalidResponse("Could not encode request body")
        }

        var request = URLRequest(url: ClaudeOAuthConfig.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClaudeOAuthConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = bodyData
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeOAuthError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeOAuthError.invalidResponse("Missing HTTP response")
        }

        let bodyString = String(data: data, encoding: .utf8) ?? "<binary>"
        guard http.statusCode == 200 else {
            switch kind {
            case .exchange:
                throw ClaudeOAuthError.exchangeFailed(status: http.statusCode, body: bodyString)
            case .refresh:
                throw ClaudeOAuthError.refreshFailed(status: http.statusCode, body: bodyString)
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeOAuthError.invalidResponse("Body is not JSON")
        }
        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String,
              let expiresIn = json["expires_in"] as? Int else {
            throw ClaudeOAuthError.invalidResponse("Missing required token fields")
        }

        let scopes = ((json["scope"] as? String) ?? ClaudeOAuthConfig.scopes)
            .split(separator: " ").map(String.init)

        let account = json["account"] as? [String: Any]
        let organization = json["organization"] as? [String: Any]

        return ClaudeOAuthTokenBundle(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            scopes: scopes,
            accountUUID: account?["uuid"] as? String,
            emailAddress: account?["email_address"] as? String,
            organizationUUID: organization?["uuid"] as? String,
            subscriptionType: json["subscription_type"] as? String,
            rateLimitTier: json["rate_limit_tier"] as? String
        )
    }
}
