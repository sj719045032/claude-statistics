import Foundation
import ClaudeStatisticsKit

/// Fetches GPT / Codex pricing from OpenAI's official pricing docs page.
final class CodexPricingFetchService: ProviderPricingFetching {
    static let shared = CodexPricingFetchService()

    private let pricingURL = "https://developers.openai.com/api/docs/pricing"

    private init() {}

    func fetchPricing() async throws -> [String: ModelPricingRates] {
        guard let url = URL(string: pricingURL) else {
            throw PricingFetchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PricingFetchError.httpError
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw PricingFetchError.parseError("Cannot decode response")
        }

        return try parsePricingFromHTML(html)
    }

    private func parsePricingFromHTML(_ html: String) throws -> [String: ModelPricingRates] {
        let compact = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let specs: [(pattern: String, modelIds: [String])] = [
            (#"gpt-5\.3-codex\s*\$([0-9.]+)\s*\$([0-9.]+)\s*\$([0-9.]+)"#, ["gpt-5.3-codex"]),
        ]

        var results: [String: ModelPricingRates] = [:]
        for spec in specs {
            if let pricing = firstMatchPricing(in: compact, pattern: spec.pattern) {
                for id in spec.modelIds {
                    results[id] = pricing
                }
            }
        }

        guard !results.isEmpty else {
            throw PricingFetchError.parseError("No Codex pricing data found")
        }

        return results
    }

    private func firstMatchPricing(in text: String, pattern: String) -> ModelPricingRates? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }

        let values = (1..<match.numberOfRanges).compactMap { index -> Double? in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Double(text[range])
        }
        guard values.count >= 2 else { return nil }

        let input = values[0]
        let cachedInput = values.count >= 3 ? values[1] : input * 0.1
        let output = values.count >= 3 ? values[2] : values[1]
        return ModelPricingRates(
            input: input,
            output: output,
            cacheWrite5m: input,
            cacheWrite1h: input,
            cacheRead: cachedInput
        )
    }
}
