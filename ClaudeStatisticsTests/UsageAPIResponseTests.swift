import XCTest

@testable import Claude_Statistics

final class UsageAPIResponseTests: XCTestCase {
    func testFableWeeklyLimitIsExposedAsUsageWindow() throws {
        let data = Data(#"""
        {
          "five_hour": {"utilization": 11, "resets_at": "2026-08-21T06:29:59Z"},
          "seven_day": {"utilization": 57, "resets_at": "2026-08-21T16:59:59Z"},
          "limits": [
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 100,
              "resets_at": "2026-08-21T16:59:59Z",
              "scope": {"model": {"id": null, "display_name": "Fable"}}
            }
          ]
        }
        """#.utf8)

        let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: data).asUsageData

        let fable = try XCTUnwrap(usage.providerBuckets?.first)
        XCTAssertEqual(fable.id, "claude-seven-day-fable")
        XCTAssertEqual(fable.remainingPercentage, 0)
        XCTAssertEqual(fable.resetsAt, "2026-08-21T16:59:59Z")
    }

    func testLegacyFableWindowTakesPrecedenceOverLimits() throws {
        let data = Data(#"""
        {
          "seven_day_fable": {"utilization": 42, "resets_at": "2026-08-22T00:00:00Z"},
          "limits": [
            {
              "kind": "weekly_scoped",
              "group": "weekly",
              "percent": 100,
              "resets_at": "2026-08-21T16:59:59Z",
              "scope": {"model": {"display_name": "Fable 5"}}
            }
          ]
        }
        """#.utf8)

        let usage = try JSONDecoder().decode(UsageAPIResponse.self, from: data).asUsageData

        let fable = try XCTUnwrap(usage.providerBuckets?.first)
        XCTAssertEqual(fable.remainingPercentage, 58)
        XCTAssertEqual(fable.resetsAt, "2026-08-22T00:00:00Z")
    }
}
