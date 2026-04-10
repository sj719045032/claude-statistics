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

    let openAIPrioritized = UsageContentOrder.sections(
        claudeHasDisplayableUsage: false,
        zaiEnabled: true,
        zaiConfigured: true,
        openAIEnabled: true,
        openAIConfigured: true
    )
    expect(
        openAIPrioritized == [.zai, .openAI, .claude],
        "Expected Z.ai, OpenAI, then Claude when Claude is unavailable but the other providers are available"
    )

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
    let emptyItems = MenuBarUsageSelection.items(
        claudeFiveHourPercent: nil,
        zaiFiveHourPercent: nil,
        openAIFiveHourPercent: nil,
        zaiEnabled: true,
        openAIEnabled: false
    )
    expect(emptyItems.isEmpty, "Expected menu bar items to be empty when both providers are invalid")
    expect(
        MenuBarUsageSelection.compactText(from: emptyItems) == nil,
        "Expected compact menu bar text to be hidden when both providers are invalid"
    )
    expect(
        MenuBarUsageSelection.displayMode(for: emptyItems) == .logo,
        "Expected the menu bar to fall back to the logo when no provider has displayable usage"
    )

    let claudeOnlyItems = MenuBarUsageSelection.items(
        claudeFiveHourPercent: 42.9,
        zaiFiveHourPercent: nil,
        openAIFiveHourPercent: nil,
        zaiEnabled: true,
        openAIEnabled: false
    )
    expect(
        claudeOnlyItems.map(\.providerLabel) == ["C"],
        "Expected Claude to appear when only Claude is valid"
    )
    expect(
        MenuBarUsageSelection.compactText(from: claudeOnlyItems) == "C 42%",
        "Expected compact text to show Claude when only Claude is valid"
    )

    let zaiOnlyItems = MenuBarUsageSelection.items(
        claudeFiveHourPercent: nil,
        zaiFiveHourPercent: 64.2,
        openAIFiveHourPercent: nil,
        zaiEnabled: true,
        openAIEnabled: false
    )
    expect(
        zaiOnlyItems.map(\.providerLabel) == ["Z"],
        "Expected Z.ai to appear when only Z.ai is valid"
    )
    expect(
        MenuBarUsageSelection.compactText(from: zaiOnlyItems) == "Z 64%",
        "Expected compact text to show Z.ai when only Z.ai is valid"
    )

    let combinedItems = MenuBarUsageSelection.items(
        claudeFiveHourPercent: 42.9,
        zaiFiveHourPercent: 64.2,
        openAIFiveHourPercent: nil,
        zaiEnabled: true,
        openAIEnabled: false
    )
    expect(
        combinedItems.map(\.providerLabel) == ["C", "Z"],
        "Expected compact menu items to preserve provider order"
    )
    expect(
        combinedItems.map(\.percentText) == ["42%", "64%"],
        "Expected compact menu items to format percentages"
    )
    expect(
        MenuBarUsageSelection.compactText(from: combinedItems) == "C 42% Z 64%",
        "Expected both provider states to appear in compact menu text"
    )

    let disabledZaiItems = MenuBarUsageSelection.items(
        claudeFiveHourPercent: 42.9,
        zaiFiveHourPercent: 64.2,
        openAIFiveHourPercent: nil,
        zaiEnabled: false,
        openAIEnabled: false
    )
    expect(
        disabledZaiItems.map(\.providerLabel) == ["C"],
        "Expected disabled Z.ai to be ignored in compact menu items"
    )

    let compactItems = MenuBarUsageSelection.items(
        claudeFiveHourPercent: 42.9,
        zaiFiveHourPercent: 64.2,
        openAIFiveHourPercent: 31.8,
        zaiEnabled: true,
        openAIEnabled: true
    )
    expect(
        compactItems.map(\.providerLabel) == ["C", "Z", "O"],
        "Expected compact menu items to keep Claude, Z.ai, OpenAI ordering"
    )
    expect(
        compactItems.map(\.percentText) == ["42%", "64%", "31%"],
        "Expected compact menu items to truncate percentages with Int(percent)"
    )
    expect(
        MenuBarUsageSelection.compactText(from: compactItems) == "C 42% Z 64% O 31%",
        "Expected compact menu text to flatten provider labels and percentages"
    )
    expect(
        MenuBarUsageSelection.displayMode(for: compactItems) == .usage(compactItems),
        "Expected the menu bar to prefer compact usage text when providers have displayable usage"
    )
    let compactFragments = MenuBarUsageSelection.styledFragments(from: compactItems)
    expect(
        compactFragments.map(\.text) == ["C", " ", "42%", " ", "Z", " ", "64%", " ", "O", " ", "31%"],
        "Expected styled fragments to preserve provider labels, separators, and percentages in order"
    )
    expect(
        compactFragments[2].style == .percentage(.green),
        "Expected Claude percentage fragments to carry a green usage tint role"
    )
    expect(
        compactFragments[6].style == .percentage(.green),
        "Expected Z.ai percentage fragments to carry a green usage tint role"
    )
    expect(
        compactFragments[10].style == .percentage(.green),
        "Expected OpenAI percentage fragments to carry a green usage tint role"
    )

    let missingMiddleItems = MenuBarUsageSelection.items(
        claudeFiveHourPercent: 42.9,
        zaiFiveHourPercent: nil,
        openAIFiveHourPercent: 31.8,
        zaiEnabled: true,
        openAIEnabled: true
    )
    expect(
        missingMiddleItems.map(\.providerLabel) == ["C", "O"],
        "Expected missing-middle provider cases to keep the remaining providers in fixed order"
    )
    expect(
        MenuBarUsageSelection.compactText(from: missingMiddleItems) == "C 42% O 31%",
        "Expected compact text to skip missing providers without adding extra separators"
    )

    let singleProviderItems = MenuBarUsageSelection.items(
        claudeFiveHourPercent: nil,
        zaiFiveHourPercent: nil,
        openAIFiveHourPercent: 31.8,
        zaiEnabled: false,
        openAIEnabled: true
    )
    expect(
        singleProviderItems.map(\.providerLabel) == ["O"],
        "Expected single-provider cases to preserve the available provider"
    )
    expect(
        MenuBarUsageSelection.compactText(from: singleProviderItems) == "O 31%",
        "Expected compact text to render a single provider without extra spacing"
    )

    let noProviderItems = MenuBarUsageSelection.items(
        claudeFiveHourPercent: nil,
        zaiFiveHourPercent: nil,
        openAIFiveHourPercent: nil,
        zaiEnabled: false,
        openAIEnabled: false
    )
    expect(noProviderItems.isEmpty, "Expected no-provider cases to produce no compact menu items")
    expect(
        MenuBarUsageSelection.compactText(from: noProviderItems) == nil,
        "Expected compact text to be nil when there are no compact menu items"
    )

    expect(
        MenuBarUsageSelection.colorRole(forUsedPercent: 69) == .green,
        "Expected 69 used percent to remain green"
    )
    expect(
        MenuBarUsageSelection.colorRole(forUsedPercent: 70) == .yellow,
        "Expected 70 used percent to switch to yellow like Quotio's used-percent menu tint"
    )
    expect(
        MenuBarUsageSelection.colorRole(forUsedPercent: 90) == .critical,
        "Expected 90 used percent to switch to critical"
    )
    expect(
        MenuBarUsageSelection.compactPercentFontSize == 10,
        "Expected compact menu percentage text to use the smaller 10pt size"
    )
    expect(
        MenuBarUsageSelection.compactProviderFontSize == 11,
        "Expected provider labels to use the larger 11pt size"
    )
    expect(
        MenuBarUsageSelection.compactProviderFontSize > MenuBarUsageSelection.compactPercentFontSize,
        "Expected provider labels to render larger than the colored percentages"
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
