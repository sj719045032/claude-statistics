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
    func parsePricingFromHTML(
        _ html: String,
        now: Date = Date()
    ) throws -> [String: ModelPricing.Pricing] {
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
            guard isPricingRowActive(modelName: modelName, at: now) else { continue }

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

    /// Sonnet 5 has two rows in Anthropic's pricing table: an introductory
    /// price through August 31, 2026 and the standard price starting the next
    /// day. Ignore the row that is not active yet (or is no longer active).
    private func isPricingRowActive(modelName: String, at date: Date) -> Bool {
        let name = modelName.lowercased()

        if name.contains("through ") {
            guard let endDate = effectiveDate(after: "through ", in: name),
                  let exclusiveEnd = Calendar.gregorianUTC.date(byAdding: .day, value: 1, to: endDate) else {
                return false
            }
            return date < exclusiveEnd
        }

        if name.contains("starting ") {
            guard let startDate = effectiveDate(after: "starting ", in: name) else {
                return false
            }
            return date >= startDate
        }

        return true
    }

    private func effectiveDate(after marker: String, in modelName: String) -> Date? {
        guard let markerRange = modelName.range(of: marker) else { return nil }
        let suffix = String(modelName[markerRange.upperBound...])
        guard let regex = try? NSRegularExpression(
            pattern: "^[a-z]+\\s+\\d{1,2},\\s+\\d{4}",
            options: .caseInsensitive
        ), let match = regex.firstMatch(
            in: suffix,
            range: NSRange(suffix.startIndex..., in: suffix)
        ), let range = Range(match.range, in: suffix) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.date(from: String(suffix[range]))
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
            ("fable 5",    ["claude-fable-5"]),
            ("mythos 5",   ["claude-mythos-5"]),
            ("mythos preview", ["claude-mythos-preview"]),
            ("opus 4.8",   ["claude-opus-4-8"]),
            ("opus 4.7",   ["claude-opus-4-7"]),
            ("opus 4.6",   ["claude-opus-4-6"]),
            ("opus 4.5",   ["claude-opus-4-5-20251101"]),
            ("opus 4.1",   ["claude-opus-4-1-20250805"]),
            ("opus 4",     ["claude-opus-4-20250514"]),
            ("opus 3",     ["claude-3-opus-20240229"]),
            ("sonnet 5",   ["claude-sonnet-5"]),
            ("sonnet 4.6", ["claude-sonnet-4-6"]),
            ("sonnet 4.5", ["claude-sonnet-4-5-20250929"]),
            ("sonnet 4",   ["claude-sonnet-4-20250514"]),
            ("sonnet 3.7", ["claude-3-7-sonnet-20250219"]),
            ("haiku 4.5",  ["claude-haiku-4-5-20251001"]),
            ("haiku 3.5",  ["claude-3-5-haiku-20241022"]),
            ("haiku 3",    ["claude-3-haiku-20240307"]),
        ]

        for mapping in mappings {
            if name.contains(mapping.pattern) {
                return mapping.ids
            }
        }

        // Fallback: construct a reasonable ID
        return [displayName.lowercased().replacingOccurrences(of: " ", with: "-")]
    }
}

private extension Calendar {
    static var gregorianUTC: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

// `CodexPricingFetchService` moved to `Plugins/Sources/CodexPlugin/`.
// `PricingFetchError` lives in `ClaudeStatisticsKit` so plugins share
// the same error vocabulary.
