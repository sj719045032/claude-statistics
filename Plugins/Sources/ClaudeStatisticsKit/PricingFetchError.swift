import Foundation

/// Error thrown by `ProviderPricingFetching.fetchPricing()`. Lives in
/// the SDK so plugins (e.g. GeminiPlugin / future Codex plugin) and
/// host-internal pricing services share the same error vocabulary.
public enum PricingFetchError: LocalizedError {
    case invalidURL
    case httpError
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid pricing URL"
        case .httpError: return "Failed to fetch pricing page"
        case .parseError(let msg): return "Parse error: \(msg)"
        }
    }
}
