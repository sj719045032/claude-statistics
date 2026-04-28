import XCTest
import ClaudeStatisticsKit

@testable import Claude_Statistics

/// Coverage for `ShareRoleEngine.makeRoleResult` and
/// `makeAllTimeRoleResult` — the dispatcher logic that turns a
/// `ShareMetrics` snapshot into a primary role + ranked score list.
///
/// Individual score functions (vibeCodingKingScore, toolSummonerScore,
/// etc.) are dense business heuristics; we test the dispatcher's
/// observable behaviours instead:
///   - Low-activity input falls back to `.steadyBuilder`.
///   - Below-threshold top scores still fall back.
///   - The daily scope excludes `.sprintHacker` from ranking.
///   - All ranked scores are returned in score-descending,
///     roleID-ascending tie-break order.
final class ShareRoleEngineTests: XCTestCase {

    // MARK: - Fixture helper

    /// Build a ShareMetrics with sensible zero-ish defaults; callers
    /// override only the fields they care about. Keeps tests focused
    /// on the dispatcher behaviour without naming all 26 fields.
    private func metrics(
        scope: StatsPeriod = .weekly,
        sessionCount: Int = 0,
        messageCount: Int = 0,
        totalTokens: Int = 0,
        totalCost: Double = 0,
        projectCount: Int = 0,
        toolUseCount: Int = 0,
        toolCategoryCount: Int = 0,
        activeDayCount: Int = 0,
        totalDayCount: Int = 7,
        nightSessionCount: Int = 0,
        nightTokenCount: Int = 0,
        cacheReadTokens: Int = 0,
        averageContextUsagePercent: Double = 0,
        averageTokensPerSession: Double = 0,
        averageMessagesPerSession: Double = 0,
        longSessionCount: Int = 0,
        modelCount: Int = 0,
        modelEntropy: Double = 0,
        peakDayTokens: Int = 0,
        peakFiveMinuteTokens: Int = 0,
        estimatedCostSessionCount: Int = 0,
        toolUseCounts: [String: Int] = [:],
        modelTokenBreakdown: [String: Int] = [:],
        providerKinds: Set<ProviderKind> = [.claude],
        providerSessionCounts: [ProviderKind: Int] = [.claude: 0],
        providerTokenCounts: [ProviderKind: Int] = [.claude: 0]
    ) -> ShareMetrics {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -7, to: end) ?? end
        return ShareMetrics(
            scope: scope,
            scopeLabel: "test",
            period: DateInterval(start: start, end: end),
            providerKinds: providerKinds,
            providerSessionCounts: providerSessionCounts,
            providerTokenCounts: providerTokenCounts,
            sessionCount: sessionCount,
            messageCount: messageCount,
            totalTokens: totalTokens,
            totalCost: totalCost,
            projectCount: projectCount,
            toolUseCount: toolUseCount,
            toolCategoryCount: toolCategoryCount,
            activeDayCount: activeDayCount,
            totalDayCount: totalDayCount,
            nightSessionCount: nightSessionCount,
            nightTokenCount: nightTokenCount,
            cacheReadTokens: cacheReadTokens,
            averageContextUsagePercent: averageContextUsagePercent,
            averageTokensPerSession: averageTokensPerSession,
            averageMessagesPerSession: averageMessagesPerSession,
            longSessionCount: longSessionCount,
            modelCount: modelCount,
            modelEntropy: modelEntropy,
            peakDayTokens: peakDayTokens,
            peakFiveMinuteTokens: peakFiveMinuteTokens,
            estimatedCostSessionCount: estimatedCostSessionCount,
            toolUseCounts: toolUseCounts,
            modelTokenBreakdown: modelTokenBreakdown
        )
    }

    // MARK: - Low-activity fallback

    func test_emptyMetrics_returnsSteadyBuilder() {
        // Zero everything → primary must be SteadyBuilder (the safety
        // floor) regardless of any latent score noise from individual
        // scoring functions.
        let result = ShareRoleEngine.makeRoleResult(
            metrics: metrics(),
            baseline: nil
        )
        XCTAssertEqual(result.roleID, .steadyBuilder)
    }

    func test_belowSessionAndTokenThreshold_returnsSteadyBuilder() {
        // Just under the threshold (sessionCount < 2 AND totalTokens <
        // 20_000). Even with otherwise-strong signals (lots of tools,
        // multiple projects), the primary should clamp to SteadyBuilder.
        let result = ShareRoleEngine.makeRoleResult(
            metrics: metrics(
                sessionCount: 1,
                messageCount: 5,
                totalTokens: 19_000,
                projectCount: 4,
                toolUseCount: 50
            ),
            baseline: nil
        )
        XCTAssertEqual(result.roleID, .steadyBuilder)
    }

    func test_allTimeBelowThreshold_returnsSteadyBuilder() {
        // All-time mode has a higher floor: sessionCount < 5 AND
        // totalTokens < 80_000.
        let result = ShareRoleEngine.makeAllTimeRoleResult(
            metrics: metrics(scope: .all, sessionCount: 4, totalTokens: 79_000),
            baseline: nil
        )
        XCTAssertEqual(result.roleID, .steadyBuilder)
    }

    // MARK: - Score-floor fallback

    func test_topScoreBelow33Percent_returnsSteadyBuilder() {
        // Just enough volume to clear the volume gate, but no signal
        // strong enough to exceed 0.33 → SteadyBuilder still wins.
        // (Each score function returns ~0 when its inputs are near zero.)
        let result = ShareRoleEngine.makeRoleResult(
            metrics: metrics(
                sessionCount: 3,
                messageCount: 10,
                totalTokens: 30_000
            ),
            baseline: nil
        )
        XCTAssertEqual(result.roleID, .steadyBuilder)
    }

    // MARK: - Daily scope excludes sprintHacker

    func test_dailyScope_doesNotIncludeSprintHacker() {
        // SprintHacker should be filtered out of the ranked list when
        // scope is .daily — same-day "sprint" is not meaningful.
        let result = ShareRoleEngine.makeRoleResult(
            metrics: metrics(scope: .daily, sessionCount: 5, messageCount: 30, totalTokens: 100_000),
            baseline: nil
        )
        XCTAssertFalse(
            result.scores.contains(where: { $0.roleID == .sprintHacker }),
            "sprintHacker must not appear in daily-scope ranking"
        )
    }

    func test_weeklyScope_includesSprintHacker() {
        // Other scopes keep all 9 roles in the ranking.
        let result = ShareRoleEngine.makeRoleResult(
            metrics: metrics(scope: .weekly, sessionCount: 5, messageCount: 30, totalTokens: 100_000),
            baseline: nil
        )
        XCTAssertTrue(result.scores.contains(where: { $0.roleID == .sprintHacker }))
    }

    func test_allTimeScope_includesAllRoles() {
        let result = ShareRoleEngine.makeAllTimeRoleResult(
            metrics: metrics(scope: .all, sessionCount: 50, messageCount: 200, totalTokens: 500_000),
            baseline: nil
        )
        XCTAssertEqual(
            Set(result.scores.map(\.roleID)).count,
            ShareRoleID.allBuiltins.count,
            "all-time ranking includes every role"
        )
    }

    // MARK: - Sort invariants

    func test_scoresAreSortedDescending() {
        let result = ShareRoleEngine.makeRoleResult(
            metrics: metrics(sessionCount: 10, messageCount: 50, totalTokens: 200_000, toolUseCount: 30),
            baseline: nil
        )
        // Scores must be monotonically non-increasing.
        let scores = result.scores.map(\.score)
        for i in 0..<(scores.count - 1) {
            XCTAssertGreaterThanOrEqual(scores[i], scores[i + 1], "scores must be in descending order")
        }
    }

    func test_tieBreaksByRoleIDRawValueAscending() {
        // With zero-everywhere metrics, every score function returns 0
        // (or near-0). Ties must break by roleID rawValue (alphabetical:
        // contextBeastTamer < efficientOperator < fullStackPathfinder <
        // multiModelDirector < nightShiftEngineer < sprintHacker <
        // steadyBuilder < toolSummoner < vibeCodingKing).
        let result = ShareRoleEngine.makeRoleResult(
            metrics: metrics(),
            baseline: nil
        )
        let allZero = result.scores.allSatisfy { $0.score == 0 }
        if allZero {
            // Verify alphabetical tie-break order across all-zero scores.
            let rawValues = result.scores.map { $0.roleID.rawValue }
            XCTAssertEqual(rawValues, rawValues.sorted())
        }
    }

    // MARK: - Result envelope

    func test_resultIncludesScopeLabel() {
        let result = ShareRoleEngine.makeRoleResult(
            metrics: metrics(),
            baseline: nil
        )
        XCTAssertEqual(result.timeScopeLabel, "test")
    }

    func test_resultIncludesAllRoleScores_weeklyScope() {
        let result = ShareRoleEngine.makeRoleResult(
            metrics: metrics(scope: .weekly),
            baseline: nil
        )
        XCTAssertEqual(result.scores.count, ShareRoleID.allBuiltins.count)
    }

    func test_resultIncludesAllRolesMinusOne_dailyScope() {
        // sprintHacker filtered out → 8 roles remain.
        let result = ShareRoleEngine.makeRoleResult(
            metrics: metrics(scope: .daily),
            baseline: nil
        )
        XCTAssertEqual(result.scores.count, ShareRoleID.allBuiltins.count - 1)
    }

    // MARK: - Plugin theme injection

    /// Builtin role wins primary → builtin theme is used; the
    /// `pluginThemes` map is consulted only for plugin role ids.
    func test_pluginThemes_unusedWhenBuiltinPrimaryWins() {
        // Strong activity → builtin primary wins (any builtin role is
        // fine; the assertion only cares the result is *not* the
        // plugin override).
        let m = metrics(
            sessionCount: 30, messageCount: 200,
            totalTokens: 5_000_000, totalCost: 12,
            projectCount: 4, toolUseCount: 200,
            toolCategoryCount: 6, activeDayCount: 6,
            totalDayCount: 7,
            averageTokensPerSession: 150_000,
            averageMessagesPerSession: 8,
            longSessionCount: 4
        )
        let altTheme = ShareVisualTheme(
            backgroundTop: .red, backgroundBottom: .red, accent: .red,
            titleGradient: [.red], titleForeground: .red, titleOutline: .red,
            titleShadowOpacity: 0, prefersLightQRCode: false,
            symbolName: "x", decorationSymbols: [],
            mascotPrimarySymbol: "x", mascotSecondarySymbols: []
        )
        // Map a fake plugin role id to the alt theme. Builtin roles
        // never appear in this dictionary, so the override must be
        // ignored — `result.visualTheme` follows the builtin switch.
        let result = ShareRoleEngine.makeRoleResult(
            metrics: m,
            baseline: nil,
            pluginThemes: ["com.example.fake": altTheme]
        )
        XCTAssertNotEqual(result.visualTheme.symbolName, "x", "builtin primary must not pick up plugin override")
        XCTAssertEqual(result.visualTheme.symbolName, result.roleID.theme.symbolName)
    }

    /// Plugin role wins primary → plugin theme overrides the
    /// steadyBuilder fallback the role would otherwise inherit.
    func test_pluginThemes_overridesFallbackWhenPluginPrimaryWins() {
        // Score-rich metrics so the plugin's clamped 1.0 score beats
        // every builtin (no builtin reaches 1.0 with mid-range inputs).
        let m = metrics(
            sessionCount: 5, messageCount: 30,
            totalTokens: 100_000, toolUseCount: 20
        )
        let pluginScores = [ShareRoleScoreEntry(roleID: "com.example.fake", score: 1.0)]
        let altTheme = ShareVisualTheme(
            backgroundTop: .red, backgroundBottom: .red, accent: .red,
            titleGradient: [.red], titleForeground: .red, titleOutline: .red,
            titleShadowOpacity: 0, prefersLightQRCode: false,
            symbolName: "plugin.symbol", decorationSymbols: [],
            mascotPrimarySymbol: "x", mascotSecondarySymbols: []
        )
        let result = ShareRoleEngine.makeRoleResult(
            metrics: m,
            baseline: nil,
            pluginScores: pluginScores,
            pluginThemes: ["com.example.fake": altTheme]
        )
        guard result.roleID.rawValue == "com.example.fake" else {
            XCTFail("plugin role should have won primary, got \(result.roleID.rawValue)")
            return
        }
        XCTAssertEqual(result.visualTheme.symbolName, "plugin.symbol")
    }
}
