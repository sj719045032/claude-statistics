import Foundation

/// Unified error vocabulary for `ProviderUsageSource` implementations
/// (Claude usage API, Codex window service, Gemini quota service, …).
/// Lives in the SDK so plugins and host-internal usage services share
/// the same matchable cases for retry / surfacing logic.
public enum UsageError: LocalizedError {
    case noCredentials
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case rateLimited(retryInSeconds: Int)
    case unauthorized
    case decodingFailed(detail: String, raw: String)

    public var errorDescription: String? {
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
