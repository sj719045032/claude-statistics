import Foundation
import ClaudeStatisticsKit

/// Fetches model pricing from Anthropic's official documentation page
/// and parses the HTML table into structured pricing data.
final class PricingFetchService: ProviderPricingFetching {
    static let shared = PricingFetchService()

    private let pricingURL = "https://platform.claude.com/docs/en/about-claude/pricing"
    private let minimumVersion = 4.5

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
    private func parsePricingFromHTML(_ html: String) throws -> [String: ModelPricing.Pricing] {
        var results: [String: ModelPricing.Pricing] = [:]

        // Extract all <tr>...</tr> blocks that contain "Claude" and "MTok"
        let trPattern = try NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>", options: .dotMatchesLineSeparators)
        let matches = trPattern.matches(in: html, range: NSRange(html.startIndex..., in: html))

        for match in matches {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let rowHTML = String(html[range])

            // Must contain Claude model name and pricing
            guard rowHTML.contains("Claude") && rowHTML.contains("MTok") else { continue }
            // Skip deprecated
            guard !rowHTML.contains("deprecated") else { continue }

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
                results[modelId] = pricing
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

    /// Check if model version is >= 4.5
    private func shouldInclude(modelName: String) -> Bool {
        for part in modelName.components(separatedBy: " ") {
            if let version = Double(part), version >= minimumVersion {
                return true
            }
        }
        return false
    }

    /// Map display names like "Claude Opus 4.6" to API model IDs
    private func mapToModelIds(displayName: String) -> [String] {
        let name = displayName.lowercased()

        let mappings: [(pattern: String, ids: [String])] = [
            // Latest
            ("opus 4.8",   ["claude-opus-4-8"]),
            ("opus 4.7",   ["claude-opus-4-7"]),
            ("opus 4.6",   ["claude-opus-4-6"]),
            ("opus 4.5",   ["claude-opus-4-5-20251101"]),
            ("opus 4.1",   ["claude-opus-4-1-20250805"]),
            ("opus 4",     ["claude-opus-4-20250514"]),
            ("opus 3",     ["claude-3-opus-20240229"]),
            ("sonnet 4.6", ["claude-sonnet-4-6"]),
            ("sonnet 4.5", ["claude-sonnet-4-5-20250929"]),
            ("sonnet 4",   ["claude-sonnet-4-20250514"]),
            ("sonnet 3.7", ["claude-3-7-sonnet-20250219"]),
            ("haiku 4.5",  ["claude-haiku-4-5-20251001", "claude-haiku-4-5"]),
            ("haiku 3.5",  ["claude-3-5-haiku-20241022"]),
            ("haiku 3",    ["claude-3-haiku-20240307"]),
        ]

        for mapping in mappings {
            // Match on a complete version token so a base pattern like
            // "opus 4" never swallows a newer minor release such as
            // "opus 4.8" (which used to fall through to the wrong base id).
            if matchesVersionToken(name, mapping.pattern) {
                return mapping.ids
            }
        }

        // Fallback for any model not in the table above (e.g. a release
        // newer than this build): derive the canonical Anthropic-style id
        // straight from the display name instead of a naive slug. This is
        // what keeps "Claude Opus 4.8" → "claude-opus-4-8" rather than the
        // old "opus-4.8" (dotted, un-prefixed) that matched nothing.
        return [canonicalModelId(from: displayName)]
    }

    /// True if `pattern` (e.g. "opus 4.8") appears in `name` as a complete
    /// version token — not as the prefix of a longer version. Without this,
    /// the "opus 4" pattern matches "claude opus 4.8" via plain `contains`
    /// and the new model gets priced as the old base model.
    private func matchesVersionToken(_ name: String, _ pattern: String) -> Bool {
        guard let range = name.range(of: pattern) else { return false }
        let rest = name[range.upperBound...]
        guard let next = rest.first else { return true }   // pattern ends the string
        if next.isNumber { return false }                  // e.g. "opus 4" vs "opus 40"
        if next == "." {
            // ".<digit>" means a longer minor version (e.g. "opus 4" vs "opus 4.8")
            if let after = rest.dropFirst().first, after.isNumber { return false }
        }
        return true
    }

    /// Derive a canonical Anthropic model id from a docs display name.
    ///   "Claude Opus 4.8"                        -> "claude-opus-4-8"
    ///   "Claude Mythos 5 (limited availability)" -> "claude-mythos-5"
    /// Drops parenthetical qualifiers and collapses dots/spaces to dashes so
    /// the id matches the dash-delimited model strings used in transcripts.
    private func canonicalModelId(from displayName: String) -> String {
        var text = displayName.lowercased()
        if let paren = text.firstIndex(of: "(") {
            text = String(text[..<paren])
        }
        let separators = CharacterSet(charactersIn: " ./_")
        let parts = text
            .components(separatedBy: separators)
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
