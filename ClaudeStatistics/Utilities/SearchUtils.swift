import Foundation
import SwiftUI
import ClaudeStatisticsKit

enum SearchUtils {

    // MARK: - Token extraction

    /// Extract searchable word tokens from a query string.
    /// Splits on non-alphanumeric/underscore characters.
    /// Filters: CJK chars kept (≥1), Latin/code tokens require ≥3 chars.
    static func extractTokens(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let wordChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return trimmed.unicodeScalars
            .split { !wordChars.contains($0) }
            .map { String($0) }
            .filter { token in
                if let scalar = token.unicodeScalars.first, scalar.value > 0x2E80 { return true }
                return token.count >= 3
            }
    }

    // MARK: - FTS query

    /// Build an FTS5 MATCH query from user input.
    /// Each token gets prefix matching (*), joined with implicit AND.
    static func ftsQuery(_ raw: String) -> String {
        let tokens = extractTokens(raw)
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\($0)*" }.joined(separator: " ")
    }

    // MARK: - Local text matching

    /// Check if text matches query using dual strategy:
    /// 1. Exact substring match (precise)
    /// 2. Token AND match (flexible, aligned with FTS)
    static func textMatches(query: String, in text: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return false }

        let lower = text.lowercased()

        // Exact substring
        if lower.contains(q) { return true }

        // Token AND match
        let tokens = extractTokens(query).map { $0.lowercased() }
        if !tokens.isEmpty {
            return tokens.allSatisfy { lower.contains($0) }
        }

        return false
    }

    // MARK: - Highlight ranges

    /// Compute character-level highlight mask for a text given a query.
    /// Returns a Bool array (same length as text) indicating which characters to highlight.
    /// Uses dual strategy: exact substring first, then token fallback.
    static func highlightMask(query: String, in text: String) -> [Bool] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [Bool](repeating: false, count: text.count) }

        let lower = text.lowercased()
        var mask = [Bool](repeating: false, count: text.count)

        // Try exact substring
        let qLower = q.lowercased()
        var foundExact = false
        var pos = lower.startIndex
        while let range = lower.range(of: qLower, range: pos..<lower.endIndex) {
            foundExact = true
            let s = lower.distance(from: lower.startIndex, to: range.lowerBound)
            let e = lower.distance(from: lower.startIndex, to: range.upperBound)
            for i in s..<min(e, mask.count) where i >= 0 { mask[i] = true }
            pos = range.upperBound
        }
        if foundExact { return mask }

        // Fallback: token-based
        for token in extractTokens(q) {
            let tLower = token.lowercased()
            var p = lower.startIndex
            while let range = lower.range(of: tLower, range: p..<lower.endIndex) {
                let s = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let e = lower.distance(from: lower.startIndex, to: range.upperBound)
                for i in s..<min(e, mask.count) where i >= 0 { mask[i] = true }
                p = range.upperBound
            }
        }
        return mask
    }

    /// Build a highlighted SwiftUI Text from a text + query, using the unified highlight mask.
    static func highlightedText(_ text: String, query: String, baseColor: Color = .primary.opacity(0.85),
                                highlightColor: Color = .yellow) -> Text {
        let mask = highlightMask(query: query, in: text)
        guard mask.contains(true) else {
            return Text(text).foregroundColor(baseColor)
        }

        let chars = Array(text)
        var result = Text("")
        var i = 0
        while i < chars.count {
            if mask[i] {
                var j = i
                while j < chars.count && mask[j] { j += 1 }
                result = result + Text(String(chars[i..<j]))
                    .bold().foregroundColor(highlightColor).underline()
                i = j
            } else {
                var j = i
                while j < chars.count && !mask[j] { j += 1 }
                result = result + Text(String(chars[i..<j])).foregroundColor(baseColor)
                i = j
            }
        }
        return result
    }

    // MARK: - Markdown with highlights

    /// Inject highlight markers into markdown text before rendering with MarkdownView.
    /// Wraps matched tokens with `==` markers (rendered as bold+italic by MarkdownView).
    static func markdownWithHighlights(_ markdown: String, query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return markdown }

        // Step 1: Strip existing inline code backticks so only our highlights get yellow
        let markdown = markdown.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)

        // Step 2: Wrap matched text with backticks for yellow inline code styling
        // Try exact substring first
        let qEscaped = NSRegularExpression.escapedPattern(for: q)
        if let regex = try? NSRegularExpression(pattern: qEscaped, options: .caseInsensitive) {
            let range = NSRange(markdown.startIndex..., in: markdown)
            if regex.firstMatch(in: markdown, range: range) != nil {
                return regex.stringByReplacingMatches(in: markdown, range: range, withTemplate: "**`$0`**")
            }
        }

        // Fallback: token-based — collect all ranges first, merge overlaps, single replacement pass
        let tokens = extractTokens(q)
        var ranges: [NSRange] = []
        for token in tokens {
            let escaped = NSRegularExpression.escapedPattern(for: token)
            if let regex = try? NSRegularExpression(pattern: escaped, options: .caseInsensitive) {
                let fullRange = NSRange(markdown.startIndex..., in: markdown)
                let matches = regex.matches(in: markdown, range: fullRange)
                for m in matches { ranges.append(m.range) }
            }
        }
        guard !ranges.isEmpty else { return markdown }

        // Sort by location and merge overlapping/adjacent ranges
        ranges.sort { $0.location < $1.location }
        var merged: [NSRange] = [ranges[0]]
        for r in ranges.dropFirst() {
            let last = merged[merged.count - 1]
            if r.location <= last.location + last.length {
                let end = max(last.location + last.length, r.location + r.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(r)
            }
        }

        // Replace from end to start to preserve earlier offsets
        var result = markdown
        for r in merged.reversed() {
            guard let swiftRange = Range(r, in: result) else { continue }
            let matched = String(result[swiftRange])
            result.replaceSubrange(swiftRange, with: "**`\(matched)`**")
        }
        return result
    }

    // MARK: - Markdown stripping

    /// Strip markdown syntax for search matching.
    /// Removes code fences, links, bold/italic, inline code, headings.
    static func stripMarkdown(_ text: String) -> String {
        TranscriptParserCommons.stripMarkdown(text)
    }
}
