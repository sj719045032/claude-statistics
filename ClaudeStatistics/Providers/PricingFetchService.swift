import Foundation
import ClaudeStatisticsKit

/// Fetches model pricing from Anthropic's official documentation page
/// and parses the HTML table into structured pricing data.
final class PricingFetchService: ProviderPricingFetching {
    static let shared = PricingFetchService()

    private let pricingURL = "https://platform.claude.com/docs/en/about-claude/pricing"

    private init() {}

    /// Fetch and parse pricing from the remote docs page
    func fetchPricing() async throws -> [String: ModelPricing.Pricing] {
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

    /// Parse pricing from HTML table rows.
    /// The page renders as HTML with <tr>/<td> tags containing data like:
    ///   <td>Claude Opus 4.6</td><td>$5 / MTok</td><td>$6.25 / MTok</td>...
    func parsePricingFromHTML(_ html: String) throws -> [String: ModelPricing.Pricing] {
        var results: [String: ModelPricing.Pricing] = [:]

        // Extract all <tr>...</tr> blocks that contain "Claude" and "MTok"
        let trPattern = try NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>", options: .dotMatchesLineSeparators)
        let matches = trPattern.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let rowHTML = String(html[range])

            // Must contain Claude model name and pricing
            guard rowHTML.contains("Claude") && rowHTML.contains("MTok") else { continue }
            // Skip deprecated rows regardless of how the docs capitalize the label.
            guard !rowHTML.lowercased().contains("deprecated") else { continue }

            // Extract all <td> cell contents
            let cells = extractTDContents(from: rowHTML)

            // Need 6 cells: Model, Input, 5m Cache, 1h Cache, Cache Read, Output
            guard cells.count >= 6 else { continue }

            let modelName = cells[0].trimmingCharacters(in: .whitespaces)
            guard modelName.contains("Claude") else { continue }

            guard let input = parseDollarValue(cells[1]),
                  let cache5m = parseDollarValue(cells[2]),
                  let cache1h = parseDollarValue(cells[3]),
                  let cacheRead = parseDollarValue(cells[4]),
                  let output = parseDollarValue(cells[5]) else { continue }

            let pricing = ModelPricing.Pricing(
                input: input, output: output,
                cacheWrite5m: cache5m, cacheWrite1h: cache1h,
                cacheRead: cacheRead
            )

            for modelId in mapToModelIds(displayName: modelName) {
                // The docs can list the same model again for future, batch, or
                // promotional pricing. The first six-column row is the current
                // standard rate shown at the top of the page.
                if results[modelId] == nil {
                    results[modelId] = pricing
                }
            }
        }

        guard !results.isEmpty else {
            throw PricingFetchError.parseError("No pricing data found (parsed \(matches.count) rows)")
        }

        return results
    }

    /// Extract text content from all <td>...</td> tags in an HTML string, stripping nested tags
    private func extractTDContents(from html: String) -> [String] {
        var cells: [String] = []

        guard let pattern = try? NSRegularExpression(pattern: "<td[^>]*>(.*?)</td>", options: .dotMatchesLineSeparators) else {
            return cells
        }

        let matches = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            if let range = Range(match.range(at: 1), in: html) {
                let raw = String(html[range])
                // Strip any remaining HTML tags
                let text = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cells.append(text)
            }
        }

        return cells
    }

    /// Parse "$5 / MTok" or "$0.80 / MTok" -> 5.0 or 0.80
    private func parseDollarValue(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "/ MTok", with: "")
            .replacingOccurrences(of: "/MTok", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    /// Map display names like "Claude Opus 4.6" to API model IDs
    private func mapToModelIds(displayName: String) -> [String] {
        let canonicalId = canonicalModelId(from: displayName)
        let aliases: [String: [String]] = [
            "claude-opus-4-5": ["claude-opus-4-5-20251101"],
            "claude-opus-4-1": ["claude-opus-4-1-20250805"],
            "claude-opus-4": ["claude-opus-4-20250514"],
            "claude-opus-3": ["claude-3-opus-20240229"],
            "claude-sonnet-4-5": ["claude-sonnet-4-5-20250929"],
            "claude-sonnet-4": ["claude-sonnet-4-20250514"],
            "claude-sonnet-3-7": ["claude-3-7-sonnet-20250219"],
            "claude-haiku-4-5": ["claude-haiku-4-5", "claude-haiku-4-5-20251001"],
            "claude-haiku-3-5": ["claude-3-5-haiku-20241022"],
            "claude-haiku-3": ["claude-3-haiku-20240307"],
        ]

        if let knownAliases = aliases[canonicalId] {
            return [canonicalId] + knownAliases.filter { $0 != canonicalId }
        }
        return [canonicalId]
    }

    /// Derive a future-proof Anthropic model id from a docs display name.
    /// Parenthetical availability notes are not part of the API model id.
    private func canonicalModelId(from displayName: String) -> String {
        var text = displayName.lowercased()
        if let paren = text.firstIndex(of: "(") {
            text = String(text[..<paren])
        }

        // Pricing rows sometimes append availability dates without
        // parentheses. Capture only the stable leading
        // "Claude <family> <version>" name while preserving decimals.
        if let regex = try? NSRegularExpression(pattern: #"^claude\s+([a-z0-9-]+)\s+([0-9]+(?:\.[0-9]+)?)"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let familyRange = Range(match.range(at: 1), in: text),
           let versionRange = Range(match.range(at: 2), in: text) {
            let family = text[familyRange]
            let version = text[versionRange].replacingOccurrences(of: ".", with: "-")
            return "claude-\(family)-\(version)"
        }

        let parts = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var id = parts.joined(separator: "-")
        if !id.hasPrefix("claude-") {
            id = "claude-" + id
        }
        return id
    }
}

// `CodexPricingFetchService` moved to `Plugins/Sources/CodexPlugin/`.
// `PricingFetchError` lives in `ClaudeStatisticsKit` so plugins share
// the same error vocabulary.
