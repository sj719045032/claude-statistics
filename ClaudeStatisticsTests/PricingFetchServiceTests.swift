import XCTest
@testable import Claude_Statistics

final class PricingFetchServiceTests: XCTestCase {
    func testParsesNewModelsWithoutFallingBackToOlderVersion() throws {
        let html = table(rows: [
            row("Claude Opus 4.8", input: "5", cache5m: "6.25", cache1h: "10", cacheRead: "0.50", output: "25"),
            row("Claude Mythos 5 (<a>limited availability</a>)", input: "10", cache5m: "12.50", cache1h: "20", cacheRead: "1", output: "50"),
        ])

        let pricing = try PricingFetchService.shared.parsePricingFromHTML(html)

        XCTAssertEqual(pricing["claude-opus-4-8"]?.output, 25)
        XCTAssertNil(pricing["claude-opus-4-20250514"])
        XCTAssertEqual(pricing["claude-mythos-5"]?.input, 10)
    }

    func testKeepsFirstCurrentRateWhenDocsIncludeFutureRate() throws {
        let html = table(rows: [
            row("Claude Sonnet 5 through August 31, 2026", input: "2", cache5m: "2.50", cache1h: "4", cacheRead: "0.20", output: "10"),
            row("Claude Sonnet 5 starting September 1, 2026", input: "3", cache5m: "3.75", cache1h: "6", cacheRead: "0.30", output: "15"),
        ])

        let pricing = try PricingFetchService.shared.parsePricingFromHTML(html)

        XCTAssertEqual(pricing["claude-sonnet-5"]?.input, 2)
        XCTAssertEqual(pricing["claude-sonnet-5"]?.output, 10)
    }

    func testKeepsFirstDuplicateStandardRow() throws {
        let html = table(rows: [
            row("Claude Opus 4.8", input: "5", cache5m: "6.25", cache1h: "10", cacheRead: "0.50", output: "25"),
            row("Claude Opus 4.8", input: "2.50", cache5m: "3.125", cache1h: "5", cacheRead: "0.25", output: "12.50"),
        ])

        let pricing = try PricingFetchService.shared.parsePricingFromHTML(html)

        XCTAssertEqual(pricing["claude-opus-4-8"]?.input, 5)
        XCTAssertEqual(pricing["claude-opus-4-8"]?.output, 25)
    }

    private func table(rows: [String]) -> String {
        "<table><tbody>\(rows.joined())</tbody></table>"
    }

    private func row(
        _ model: String,
        input: String,
        cache5m: String,
        cache1h: String,
        cacheRead: String,
        output: String
    ) -> String {
        """
        <tr>
          <td>\(model)</td><td>$\(input) / MTok</td><td>$\(cache5m) / MTok</td>
          <td>$\(cache1h) / MTok</td><td>$\(cacheRead) / MTok</td><td>$\(output) / MTok</td>
        </tr>
        """
    }
}
