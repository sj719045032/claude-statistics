import XCTest
import Foundation
import ClaudeStatisticsKit

@testable import Claude_Statistics

final class PricingFetchServiceTests: XCTestCase {
    func testCurrentClaudeModelsMapToCanonicalIDs() throws {
        let models = try PricingFetchService.shared.parsePricingFromHTML(
            """
            <table>
            \(row("Claude Fable 5", input: 10, cache5m: 12.5, cache1h: 20, read: 1, output: 50))
            \(row("Claude Mythos 5 (<a href=\"#\">limited availability</a>)", input: 10, cache5m: 12.5, cache1h: 20, read: 1, output: 50))
            \(row("Claude Opus 4.8", input: 5, cache5m: 6.25, cache1h: 10, read: 0.5, output: 25))
            </table>
            """,
            now: utcDate(year: 2026, month: 7, day: 10)
        )

        XCTAssertEqual(models["claude-fable-5"], pricing(10, 50, 12.5, 20, 1))
        XCTAssertEqual(models["claude-mythos-5"], pricing(10, 50, 12.5, 20, 1))
        XCTAssertEqual(models["claude-opus-4-8"], pricing(5, 25, 6.25, 10, 0.5))
        XCTAssertNil(models["claude-opus-4-20250514"])
        XCTAssertNil(models["claude-mythos-5-(limited-availability)"])
    }

    func testSonnet5UsesIntroductoryPriceThroughAugust2026() throws {
        let models = try PricingFetchService.shared.parsePricingFromHTML(
            sonnet5HTML,
            now: utcDate(year: 2026, month: 8, day: 31, hour: 23, minute: 59, second: 59)
        )

        XCTAssertEqual(models["claude-sonnet-5"], pricing(2, 10, 2.5, 4, 0.2))
        XCTAssertEqual(models.keys.filter { $0.contains("sonnet-5") }.count, 1)
    }

    func testSonnet5UsesStandardPriceStartingSeptember2026() throws {
        let models = try PricingFetchService.shared.parsePricingFromHTML(
            sonnet5HTML,
            now: utcDate(year: 2026, month: 9, day: 1)
        )

        XCTAssertEqual(models["claude-sonnet-5"], pricing(3, 15, 3.75, 6, 0.3))
    }

    func testBuiltinCatalogUsesScheduledSonnet5Price() {
        let intro = ClaudePricingCatalog.models(at: utcDate(year: 2026, month: 8, day: 31))
        let standard = ClaudePricingCatalog.models(at: utcDate(year: 2026, month: 9, day: 1))

        XCTAssertNotNil(intro["claude-fable-5"])
        XCTAssertNotNil(intro["claude-mythos-5"])
        XCTAssertNotNil(intro["claude-opus-4-8"])
        XCTAssertEqual(intro["claude-sonnet-5"], pricing(2, 10, 2.5, 4, 0.2))
        XCTAssertEqual(standard["claude-sonnet-5"], pricing(3, 15, 3.75, 6, 0.3))
    }

    func testRepairsLegacyOpus48Miskey() {
        let opus48 = pricing(5, 25, 6.25, 10, 0.5)
        let repaired = ModelPricing.repairedClaudePricingModels(
            [
                "claude-opus-4-20250514": opus48,
                "claude-mythos-5-(limited-availability)": pricing(10, 50, 12.5, 20, 1),
            ],
            now: utcDate(year: 2026, month: 7, day: 10)
        )

        XCTAssertEqual(repaired["claude-opus-4-8"], opus48)
        XCTAssertNil(repaired["claude-opus-4-20250514"])
    }

    func testDoesNotMoveUserCustomizedLegacyOpusPriceWithoutParserArtifacts() {
        let custom = pricing(5, 25, 6.25, 10, 0.5)
        let repaired = ModelPricing.repairedClaudePricingModels(
            ["claude-opus-4-20250514": custom],
            now: utcDate(year: 2026, month: 7, day: 10)
        )

        XCTAssertEqual(repaired["claude-opus-4-20250514"], custom)
        XCTAssertNil(repaired["claude-opus-4-8"])
    }

    func testRepairsLegacyMythosID() {
        let mythos = pricing(10, 50, 12.5, 20, 1)
        let repaired = ModelPricing.repairedClaudePricingModels(
            ["claude-mythos-5-(limited-availability)": mythos],
            now: utcDate(year: 2026, month: 7, day: 10)
        )

        XCTAssertEqual(repaired["claude-mythos-5"], mythos)
        XCTAssertNil(repaired["claude-mythos-5-(limited-availability)"])
    }

    func testRepairsExpiredSonnet5IntroductoryPrice() {
        let repaired = ModelPricing.repairedClaudePricingModels(
            ["claude-sonnet-5": pricing(2, 10, 2.5, 4, 0.2)],
            now: utcDate(year: 2026, month: 9, day: 1)
        )

        XCTAssertEqual(repaired["claude-sonnet-5"], pricing(3, 15, 3.75, 6, 0.3))
    }

    func testScheduledSonnet5LookupPreservesCustomPrice() {
        let custom = pricing(2.25, 11, 2.75, 4.5, 0.25)
        let effective = ModelPricing.effectiveClaudePricing(
            custom,
            modelID: "claude-sonnet-5",
            at: utcDate(year: 2026, month: 9, day: 1)
        )

        XCTAssertEqual(effective, custom)
    }

    func testScheduledSonnet5LookupChangesAtExactBoundary() {
        let intro = pricing(2, 10, 2.5, 4, 0.2)
        let before = ModelPricing.effectiveClaudePricing(
            intro,
            modelID: "claude-sonnet-5",
            at: utcDate(year: 2026, month: 8, day: 31, hour: 23, minute: 59, second: 59)
        )
        let after = ModelPricing.effectiveClaudePricing(
            intro,
            modelID: "claude-sonnet-5",
            at: utcDate(year: 2026, month: 9, day: 1)
        )

        XCTAssertEqual(before, intro)
        XCTAssertEqual(after, pricing(3, 15, 3.75, 6, 0.3))
    }

    func testClaudeFallbackKeepsVersionedModelsWithSuffixes() {
        XCTAssertEqual(
            ModelPricing.claudeFallbackModelID(for: "claude-sonnet-4-6[1m]"),
            "claude-sonnet-4-6"
        )
        XCTAssertEqual(
            ModelPricing.claudeFallbackModelID(for: "claude-3-7-sonnet-20250219[1m]"),
            "claude-3-7-sonnet-20250219"
        )
        XCTAssertEqual(
            ModelPricing.claudeFallbackModelID(for: "claude-3-5-haiku-20241022[1m]"),
            "claude-3-5-haiku-20241022"
        )
        XCTAssertEqual(ModelPricing.claudeFallbackModelID(for: "sonnet"), "claude-sonnet-5")
        XCTAssertEqual(ModelPricing.claudeFallbackModelID(for: "opus"), "claude-opus-4-8")
    }

    func testStatusLineNormalizesPersistedSonnet5PriceAtCutover() throws {
        let script = StatusLineInstaller.generatedScript()
        let startMarker = "python3 -c '\n"
        let endMarker = "\n' 2>"
        guard let start = script.range(of: startMarker),
              let end = script.range(of: endMarker, range: start.upperBound..<script.endIndex) else {
            return XCTFail("Could not extract embedded status-line Python")
        }

        var python = String(script[start.upperBound..<end.lowerBound])
        let dynamicAssignment = "sonnet_5 = sonnet_5_intro if time.time() < 1788220800 else sonnet_5_standard"
        XCTAssertTrue(python.contains(dynamicAssignment))
        python = python.replacingOccurrences(
            of: dynamicAssignment,
            with: "sonnet_5 = sonnet_5_standard"
        )
        python += """

        app_pricing = {
            "claude-sonnet-5": {
                "input": 2.0, "output": 10.0,
                "cache_write_1h": 4.0, "cache_read": 0.2,
            }
        }
        assert get_pricing("claude-sonnet-5") == sonnet_5_standard
        app_pricing["claude-sonnet-5"] = {
            "input": 2.25, "output": 11.0,
            "cache_write_1h": 4.5, "cache_read": 0.25,
        }
        assert get_pricing("claude-sonnet-5") == (2.25, 11.0, 4.5, 0.25)
        """

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-line-pricing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", python]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CS_FILES": "",
            "CS_TCACHE": cacheURL.path,
        ]) { _, testValue in testValue }
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errorText = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, errorText)
    }

    func testRepairsLegacySonnet5DateIDs() {
        let repaired = ModelPricing.repairedClaudePricingModels(
            [
                "claude-sonnet-5through-august-31,-2026": pricing(2, 10, 2.5, 4, 0.2),
                "claude-sonnet-5starting-september-1,-2026": pricing(3, 15, 3.75, 6, 0.3),
            ],
            now: utcDate(year: 2026, month: 7, day: 10)
        )

        XCTAssertEqual(repaired["claude-sonnet-5"], pricing(2, 10, 2.5, 4, 0.2))
        XCTAssertFalse(repaired.keys.contains { $0.contains("sonnet-5through-") })
        XCTAssertFalse(repaired.keys.contains { $0.contains("sonnet-5starting-") })
    }

    private var sonnet5HTML: String {
        """
        <table>
        \(row("Claude Sonnet 5<br/><a href=\"#\">through August 31, 2026</a>", input: 2, cache5m: 2.5, cache1h: 4, read: 0.2, output: 10))
        \(row("Claude Sonnet 5<br/><a href=\"#\">starting September 1, 2026</a>", input: 3, cache5m: 3.75, cache1h: 6, read: 0.3, output: 15))
        </table>
        """
    }

    private func row(
        _ name: String,
        input: Double,
        cache5m: Double,
        cache1h: Double,
        read: Double,
        output: Double
    ) -> String {
        """
        <tr><td>\(name)</td><td>$\(input) / MTok</td><td>$\(cache5m) / MTok</td><td>$\(cache1h) / MTok</td><td>$\(read) / MTok</td><td>$\(output) / MTok</td></tr>
        """
    }

    private func pricing(
        _ input: Double,
        _ output: Double,
        _ cache5m: Double,
        _ cache1h: Double,
        _ read: Double
    ) -> ModelPricing.Pricing {
        ModelPricing.Pricing(
            input: input,
            output: output,
            cacheWrite5m: cache5m,
            cacheWrite1h: cache1h,
            cacheRead: read
        )
    }

    private func utcDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }
}
