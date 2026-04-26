import Foundation
import ClaudeStatisticsKit

final class GeminiPricingFetchService: ProviderPricingFetching {
    static let shared = GeminiPricingFetchService()

    private let pricingURL = "https://ai.google.dev/gemini-api/docs/pricing"

    private init() {}

    func fetchPricing() async throws -> [String: ModelPricing.Pricing] {
        guard let url = URL(string: pricingURL) else {
            throw PricingFetchError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PricingFetchError.httpError
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw PricingFetchError.parseError("Cannot decode response")
        }

        return try parsePricingFromHTML(html)
    }

    private func parsePricingFromHTML(_ html: String) throws -> [String: ModelPricing.Pricing] {
        let text = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let specs: [(heading: String, modelIds: [String])] = [
            ("Gemini 3.1 Pro Preview", ["gemini-3.1-pro-preview", "gemini-3.1-pro-preview-customtools", "gemini-3-pro-preview"]),
            ("Gemini 3.1 Flash-Lite Preview", ["gemini-3.1-flash-lite-preview"]),
            ("Gemini 3 Flash Preview", ["gemini-3-flash-preview"]),
            ("Gemini 2.5 Pro", ["gemini-2.5-pro"]),
            ("Gemini 2.5 Flash", ["gemini-2.5-flash", "gemini-2.5-flash-preview-09-2025"]),
            ("Gemini 2.5 Flash-Lite", ["gemini-2.5-flash-lite"]),
            ("Gemini 2.5 Flash-Lite Preview", ["gemini-2.5-flash-lite-preview-09-2025"]),
        ]

        var results: [String: ModelPricing.Pricing] = [:]
        for spec in specs {
            guard let section = section(named: spec.heading, in: text) else { continue }
            guard let standard = standardSection(in: section) else { continue }
            guard let input = firstDollar(after: "Input price", in: standard),
                  let output = firstDollar(after: "Output price", in: standard) else {
                continue
            }

            let cache = firstDollar(after: "Context caching price", in: standard) ?? (input * 0.1)
            let pricing = ModelPricing.Pricing(
                input: input,
                output: output,
                cacheWrite5m: cache,
                cacheWrite1h: cache,
                cacheRead: cache
            )

            for id in spec.modelIds {
                results[id] = pricing
            }
        }

        guard !results.isEmpty else {
            throw PricingFetchError.parseError("No Gemini pricing data found")
        }

        return results
    }

    private func section(named heading: String, in text: String) -> String? {
        guard let start = text.range(of: heading) else { return nil }
        let remainder = text[start.lowerBound...]
        let nextHeading = remainder.dropFirst(heading.count).range(of: " Gemini ")
        if let nextHeading {
            return String(remainder[..<nextHeading.lowerBound])
        }
        return String(remainder)
    }

    private func standardSection(in section: String) -> String? {
        guard let start = section.range(of: "Standard") else { return nil }
        let remainder = section[start.lowerBound...]
        if let end = remainder.range(of: " Batch") {
            return String(remainder[..<end.lowerBound])
        }
        return String(remainder)
    }

    private func firstDollar(after label: String, in text: String) -> Double? {
        guard let labelRange = text.range(of: label) else { return nil }
        let remainder = String(text[labelRange.upperBound...])
        guard let regex = try? NSRegularExpression(pattern: #"\$([0-9]+(?:\.[0-9]+)?)"#),
              let match = regex.firstMatch(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)),
              let range = Range(match.range(at: 1), in: remainder) else {
            return nil
        }
        return Double(remainder[range])
    }
}
