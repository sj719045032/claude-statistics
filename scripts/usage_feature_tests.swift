import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        fatalError("Invalid ISO8601 date: \(value)")
    }
    return date
}

func sameMoment(_ lhs: Date, _ rhs: Date) -> Bool {
    abs(lhs.timeIntervalSince(rhs)) < 0.001
}

func runUsageContentOrderTests() {
    let prioritized = UsageContentOrder.sections(
        claudeHasDisplayableUsage: false,
        zaiEnabled: true,
        zaiConfigured: true
    )
    expect(prioritized == [.zai, .claude], "Expected Z.ai to be shown first when Claude usage is invalid")

    let defaultOrder = UsageContentOrder.sections(
        claudeHasDisplayableUsage: true,
        zaiEnabled: true,
        zaiConfigured: true
    )
    expect(defaultOrder == [.claude, .zai], "Expected Claude to stay first when Claude usage is available")

    let claudeOnly = UsageContentOrder.sections(
        claudeHasDisplayableUsage: true,
        zaiEnabled: true,
        zaiConfigured: false
    )
    expect(claudeOnly == [.claude], "Expected only Claude section when Z.ai is not configured")

    let disabledZai = UsageContentOrder.sections(
        claudeHasDisplayableUsage: false,
        zaiEnabled: false,
        zaiConfigured: true
    )
    expect(disabledZai == [.claude], "Expected Claude-only layout when Z.ai is disabled")
}

func runZaiTimeRangeTests() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let reference = isoDate("2026-03-29T09:42:00Z")

    let dayWindow = ZaiUsageRange.day.requestWindow(relativeTo: reference, calendar: calendar)
    expect(
        sameMoment(dayWindow.start, isoDate("2026-03-29T00:00:00Z")),
        "Expected day range to start at the beginning of the current day"
    )
    expect(
        sameMoment(dayWindow.end, isoDate("2026-03-29T23:59:59Z")),
        "Expected day range to end at the end of the current day"
    )

    let weekWindow = ZaiUsageRange.week.requestWindow(relativeTo: reference, calendar: calendar)
    expect(
        sameMoment(weekWindow.start, isoDate("2026-03-23T00:00:00Z")),
        "Expected week range to cover the current day plus the previous six days"
    )
    expect(
        sameMoment(weekWindow.end, isoDate("2026-03-29T23:59:59Z")),
        "Expected week range to end at the end of the current day"
    )
}

func runZaiModelUsageAggregationTests() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let usage = ZaiModelUsageDisplay(
        points: [
            ZaiChartPoint(time: isoDate("2026-03-23T02:00:00Z"), calls: 1, tokens: 100),
            ZaiChartPoint(time: isoDate("2026-03-23T18:00:00Z"), calls: 2, tokens: 250),
            ZaiChartPoint(time: isoDate("2026-03-24T09:30:00Z"), calls: 3, tokens: 400)
        ],
        totalCalls: 6,
        totalTokens: 750
    )

    let dayPoints = usage.chartPoints(for: .day, calendar: calendar)
    expect(dayPoints.count == 3, "Expected day range to preserve original data granularity")
    expect(
        sameMoment(dayPoints[0].time, isoDate("2026-03-23T02:00:00Z")),
        "Expected day range points to stay time-sorted"
    )

    let weekPoints = usage.chartPoints(for: .week, calendar: calendar)
    expect(weekPoints.count == 2, "Expected week range to aggregate points by day")
    expect(
        sameMoment(weekPoints[0].time, isoDate("2026-03-23T00:00:00Z")),
        "Expected aggregated week point to use the start of day"
    )
    expect(weekPoints[0].calls == 3, "Expected week aggregation to sum calls within the same day")
    expect(weekPoints[0].tokens == 350, "Expected week aggregation to sum tokens within the same day")
    expect(weekPoints[1].calls == 3, "Expected single-day points to stay unchanged after aggregation")
    expect(weekPoints[1].tokens == 400, "Expected aggregated tokens to remain correct for unique days")
}

func runMenuBarUsageSelectionTests() {
    expect(
        MenuBarUsageSelection.text(
            claudeFiveHourPercent: nil,
            zaiFiveHourPercent: nil,
            zaiEnabled: true,
            authMode: .oauth
        ) == nil,
        "Expected menu bar text to be hidden when both providers are invalid"
    )

    expect(
        MenuBarUsageSelection.text(
            claudeFiveHourPercent: 42.9,
            zaiFiveHourPercent: nil,
            zaiEnabled: true,
            authMode: .apiKey
        ) == "42%",
        "Expected Claude percentage to be shown when only Claude is valid"
    )

    expect(
        MenuBarUsageSelection.text(
            claudeFiveHourPercent: nil,
            zaiFiveHourPercent: 64.2,
            zaiEnabled: true,
            authMode: .oauth
        ) == "64%",
        "Expected Z.ai percentage to be shown when only Z.ai is valid"
    )

    expect(
        MenuBarUsageSelection.text(
            claudeFiveHourPercent: 42.9,
            zaiFiveHourPercent: 64.2,
            zaiEnabled: true,
            authMode: .apiKey
        ) == "64%",
        "Expected api-key mode to prefer Z.ai when both providers are valid"
    )

    expect(
        MenuBarUsageSelection.text(
            claudeFiveHourPercent: 42.9,
            zaiFiveHourPercent: 64.2,
            zaiEnabled: true,
            authMode: .oauth
        ) == "42%",
        "Expected oauth mode to prefer Claude when both providers are valid"
    )

    expect(
        MenuBarUsageSelection.text(
            claudeFiveHourPercent: 42.9,
            zaiFiveHourPercent: 64.2,
            zaiEnabled: false,
            authMode: .apiKey
        ) == "42%",
        "Expected disabled Z.ai to be ignored in menu bar selection"
    )
}

func runReminderPlannerTests() {
    let resetAt = isoDate("2026-03-29T15:00:00Z")
    let now = isoDate("2026-03-29T10:00:00Z")

    let schedule = UsageResetReminderPlanner.action(
        isEnabled: true,
        utilization: 100,
        resetAt: resetAt,
        lastScheduledResetAt: nil,
        now: now
    )
    expect(schedule == .schedule(resetAt), "Expected a reminder to be scheduled when usage reaches 100%")

    let deduped = UsageResetReminderPlanner.action(
        isEnabled: true,
        utilization: 120,
        resetAt: resetAt,
        lastScheduledResetAt: resetAt,
        now: now
    )
    expect(deduped == .none, "Expected duplicate reminder scheduling to be ignored")

    let cancel = UsageResetReminderPlanner.action(
        isEnabled: false,
        utilization: 120,
        resetAt: resetAt,
        lastScheduledResetAt: resetAt,
        now: now
    )
    expect(cancel == .cancel, "Expected pending reminders to be cancelled when the setting is disabled")
}

func runNotificationActionVisibilityTests() {
    expect(
        NotificationActionVisibility.shouldShowAllowButton(notificationsAuthorized: false),
        "Expected Allow Notifications button to stay visible before system authorization is granted"
    )

    expect(
        !NotificationActionVisibility.shouldShowAllowButton(notificationsAuthorized: true),
        "Expected Allow Notifications button to be hidden once system authorization is granted"
    )
}

@main
struct UsageFeatureTestsRunner {
    static func main() {
        runUsageContentOrderTests()
        runZaiTimeRangeTests()
        runZaiModelUsageAggregationTests()
        runMenuBarUsageSelectionTests()
        runReminderPlannerTests()
        runNotificationActionVisibilityTests()
        print("usage_feature_tests passed")
    }
}
