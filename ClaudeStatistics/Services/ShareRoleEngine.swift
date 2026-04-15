import Foundation

enum ShareRoleEngine {
    static func makeRoleResult(metrics: ShareMetrics, baseline: ShareMetrics?) -> ShareRoleResult {
        let ranked = rankedRoles(metrics: metrics, baseline: baseline)
        let primary = choosePrimaryRole(from: ranked, metrics: metrics)
        return buildRoleResult(primary: primary, ranked: ranked, metrics: metrics)
    }

    static func makeAllTimeRoleResult(metrics: ShareMetrics, baseline: ShareMetrics?) -> ShareRoleResult {
        let ranked = rankedAllTimeRoles(metrics: metrics, baseline: baseline)
        let primary = chooseAllTimePrimaryRole(from: ranked, metrics: metrics)
        return buildRoleResult(primary: primary, ranked: ranked, metrics: metrics)
    }

    private static func buildRoleResult(primary: ShareRoleID, ranked: [ShareRoleScore], metrics: ShareMetrics) -> ShareRoleResult {
        let badges = selectBadges(metrics: metrics, primaryRole: primary)
        let subtitle = subtitle(for: primary, metrics: metrics)
        let summary = summary(for: primary, metrics: metrics)
        let proofMetrics = proofMetrics(for: primary, metrics: metrics)

        return ShareRoleResult(
            roleID: primary,
            roleName: primary.displayName,
            subtitle: subtitle,
            summary: summary,
            timeScopeLabel: metrics.scopeLabel,
            providerSummary: providerSummary(for: metrics),
            visualTheme: primary.theme,
            badges: badges,
            proofMetrics: proofMetrics,
            scores: ranked
        )
    }

    private static func rankedRoles(metrics: ShareMetrics, baseline: ShareMetrics?) -> [ShareRoleScore] {
        let scores: [(ShareRoleID, Double)] = [
            (.vibeCodingKing, vibeCodingKingScore(metrics: metrics, baseline: baseline)),
            (.toolSummoner, toolSummonerScore(metrics: metrics, baseline: baseline)),
            (.contextBeastTamer, contextBeastTamerScore(metrics: metrics, baseline: baseline)),
            (.nightShiftEngineer, nightShiftEngineerScore(metrics: metrics, baseline: baseline)),
            (.multiModelDirector, multiModelDirectorScore(metrics: metrics, baseline: baseline)),
            (.sprintHacker, sprintHackerScore(metrics: metrics, baseline: baseline)),
            (.fullStackPathfinder, fullStackPathfinderScore(metrics: metrics, baseline: baseline)),
            (.efficientOperator, efficientOperatorScore(metrics: metrics, baseline: baseline)),
            (.steadyBuilder, steadyBuilderScore(metrics: metrics, baseline: baseline))
        ]

        return scores
            .filter { !(metrics.scope == .daily && $0.0 == .sprintHacker) }
            .map { ShareRoleScore(roleID: $0.0, score: $0.1) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.roleID.rawValue < rhs.roleID.rawValue
                }
                return lhs.score > rhs.score
            }
    }

    private static func rankedAllTimeRoles(metrics: ShareMetrics, baseline: ShareMetrics?) -> [ShareRoleScore] {
        let scores: [(ShareRoleID, Double)] = [
            (.vibeCodingKing, allTimeVibeCodingKingScore(metrics: metrics, baseline: baseline)),
            (.toolSummoner, allTimeToolSummonerScore(metrics: metrics, baseline: baseline)),
            (.contextBeastTamer, allTimeContextBeastTamerScore(metrics: metrics, baseline: baseline)),
            (.nightShiftEngineer, allTimeNightShiftEngineerScore(metrics: metrics, baseline: baseline)),
            (.multiModelDirector, allTimeMultiModelDirectorScore(metrics: metrics, baseline: baseline)),
            (.sprintHacker, allTimeSprintHackerScore(metrics: metrics, baseline: baseline)),
            (.fullStackPathfinder, allTimeFullStackPathfinderScore(metrics: metrics, baseline: baseline)),
            (.efficientOperator, allTimeEfficientOperatorScore(metrics: metrics, baseline: baseline)),
            (.steadyBuilder, allTimeSteadyBuilderScore(metrics: metrics, baseline: baseline))
        ]

        return scores
            .map { ShareRoleScore(roleID: $0.0, score: $0.1) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.roleID.rawValue < rhs.roleID.rawValue
                }
                return lhs.score > rhs.score
            }
    }

    private static func choosePrimaryRole(from ranked: [ShareRoleScore], metrics: ShareMetrics) -> ShareRoleID {
        guard let top = ranked.first else { return .steadyBuilder }
        if metrics.sessionCount < 2 && metrics.totalTokens < 20_000 {
            return .steadyBuilder
        }
        if top.score < 0.33 {
            return .steadyBuilder
        }

        if genericRoleIDs.contains(top.roleID),
           let specialist = identitySpecialistCandidate(
            from: ranked,
            top: top,
            metrics: metrics,
            minimumScore: genericSpecialistMinimumScore(for: metrics.scope, topRole: top.roleID),
            maximumGap: genericSpecialistMaximumGap(for: metrics.scope, topRole: top.roleID)
           ) {
            return specialist.roleID
        }
        return top.roleID
    }

    private static func chooseAllTimePrimaryRole(from ranked: [ShareRoleScore], metrics: ShareMetrics) -> ShareRoleID {
        guard let top = ranked.first else { return .steadyBuilder }
        if metrics.sessionCount < 5 && metrics.totalTokens < 80_000 {
            return .steadyBuilder
        }
        if top.score < 0.35 {
            return .steadyBuilder
        }

        if genericRoleIDs.contains(top.roleID) {
            if let specialist = identitySpecialistCandidate(
                from: ranked,
                top: top,
                metrics: metrics,
                minimumScore: 0.50,
                maximumGap: 0.16
            ) {
                return specialist.roleID
            }
        }

        if top.roleID == .steadyBuilder {
            if let pathfinder = ranked.first(where: { $0.roleID == .fullStackPathfinder }),
               metrics.projectCount >= 8,
               metrics.activeDayCount >= 14,
               pathfinder.score >= top.score - 0.06 {
                return .fullStackPathfinder
            }

            if let director = ranked.first(where: { $0.roleID == .multiModelDirector }),
               director.score >= 0.62,
               director.score >= top.score - 0.08 {
                return .multiModelDirector
            }
        }

        return top.roleID
    }

    private static func vibeCodingKingScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        if metrics.scope == .yearly {
            return longHorizonVibeCodingKingScore(metrics: metrics, baseline: baseline)
        }

        var score =
            0.28 * countScore(Double(metrics.toolUseCount), baseline?.toolUseCount) +
            0.24 * countScore(Double(metrics.sessionCount), baseline?.sessionCount) +
            0.16 * countScore(Double(metrics.projectCount), baseline?.projectCount) +
            0.15 * countScore(Double(metrics.messageCount), baseline?.messageCount) +
            0.07 * ratioScore(metrics.activeDayCoverage, baseline?.activeDayCoverage) +
            0.10 * countScore(metrics.averageTokensPerSession, baseline?.averageTokensPerSession)
        if metrics.sessionCount >= 8 && metrics.toolUseCount >= 40 {
            score += 0.08
        }
        if hasStrongNightSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongMultiModelSignature(metrics) {
            score -= 0.16
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.10
        }
        return min(score, 1.2)
    }

    private static func toolSummonerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateToolSignature(metrics) else { return 0 }
        var score =
            0.52 * countScore(metrics.toolUsePerMessage, baseline?.toolUsePerMessage) +
            0.30 * countScore(Double(metrics.toolCategoryCount), baseline?.toolCategoryCount) +
            0.18 * countScore(Double(metrics.toolUseCount), baseline?.toolUseCount)
        if hasStrongToolSignature(metrics) {
            score += 0.12
        }
        if hasModerateToolSignature(metrics) {
            score += metrics.scope == .monthly || metrics.scope == .yearly ? 0.03 : 0.06
        }
        if metrics.scope == .monthly || metrics.scope == .yearly {
            score -= 0.06
        }
        if hasModerateContextSignature(metrics) || hasModerateMultiModelSignature(metrics) {
            score -= 0.06
        }
        return min(score, 1.2)
    }

    private static func contextBeastTamerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateContextSignature(metrics) else { return 0 }
        var score =
            0.32 * ratioScore(metrics.averageContextUsagePercent / 100.0, baseline.map { $0.averageContextUsagePercent / 100.0 }) +
            0.22 * countScore(Double(metrics.cacheReadTokens), baseline?.cacheReadTokens) +
            0.24 * ratioScore(metrics.longSessionRatio, baseline?.longSessionRatio) +
            0.14 * ratioScore(cacheReadRatio(metrics), baseline.map(cacheReadRatio)) +
            0.08 * countScore(metrics.averageTokensPerSession, baseline?.averageTokensPerSession)
        if hasStrongContextSignature(metrics) {
            score += 0.12
        }
        if hasModerateContextSignature(metrics) {
            score += 0.04
        }
        if hasModerateToolSignature(metrics) || hasModerateMultiModelSignature(metrics) || hasModerateNightSignature(metrics) {
            score -= 0.08
        }
        return min(score, 1.2)
    }

    private static func nightShiftEngineerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateNightSignature(metrics) else { return 0 }
        var score =
            0.50 * ratioScore(metrics.nightTokenRatio, baseline?.nightTokenRatio) +
            0.30 * ratioScore(metrics.nightSessionRatio, baseline?.nightSessionRatio) +
            0.20 * countScore(Double(metrics.nightSessionCount), baseline?.nightSessionCount)
        if hasStrongNightSignature(metrics) {
            score += 0.18
        }
        if hasModerateNightSignature(metrics) {
            score += 0.08
        }
        return min(score, 1.2)
    }

    private static func multiModelDirectorScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateMultiModelSignature(metrics) else { return 0 }
        let adjustedModelCount = providerAdjustedModelCount(metrics)
        let baselineAdjustedModelCount = baseline.map(providerAdjustedModelCount)
        var score =
            0.12 * rangeScore(Double(metrics.providerCount), min: 1, max: 3) +
            0.46 * countScore(Double(adjustedModelCount), baselineAdjustedModelCount) +
            0.32 * ratioScore(metrics.modelEntropy, baseline?.modelEntropy) +
            0.10 * rangeScore(Double(metrics.modelCount), min: 2, max: 10)
        if hasStrongMultiModelSignature(metrics) {
            score += 0.16
        }
        if hasModerateMultiModelSignature(metrics) {
            score += 0.10
        }
        if metrics.providerCount >= 2 && adjustedModelCount < 3 {
            score -= 0.22
        }
        return min(score, 1.2)
    }

    private static func sprintHackerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard metrics.scope != .daily else { return 0 }
        let burstiness = metrics.totalTokens > 0 ? Double(metrics.peakFiveMinuteTokens) / Double(metrics.totalTokens) : 0
        let baselineBurstiness = baseline.map { $0.totalTokens > 0 ? Double($0.peakFiveMinuteTokens) / Double($0.totalTokens) : 0 }
        let score =
            0.40 * ratioScore(metrics.singleDayPeakRatio, baseline?.singleDayPeakRatio) +
            0.35 * countScore(Double(metrics.peakFiveMinuteTokens), baseline?.peakFiveMinuteTokens) +
            0.25 * ratioScore(burstiness, baselineBurstiness)
        if hasStrongSprintSignature(metrics) {
            return min(score + 0.16, 1.2)
        }
        return min(score, 1.2)
    }

    private static func fullStackPathfinderScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        if metrics.scope == .yearly {
            return longHorizonFullStackPathfinderScore(metrics: metrics, baseline: baseline)
        }

        var score =
            0.38 * countScore(Double(metrics.projectCount), baseline?.projectCount) +
            0.30 * ratioScore(metrics.activeDayCoverage, baseline?.activeDayCoverage) +
            0.18 * (1.0 - ratioScore(metrics.singleDayPeakRatio, baseline?.singleDayPeakRatio)) +
            0.14 * countScore(Double(metrics.sessionCount), baseline?.sessionCount)
        if metrics.projectCount >= 4 && metrics.activeDayCoverage >= 0.5 {
            score += 0.08
        }
        if hasStrongToolSignature(metrics) || hasStrongNightSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongSprintSignature(metrics) {
            score -= 0.18
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.08
        }
        return min(score, 1.2)
    }

    private static func efficientOperatorScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard metrics.totalCost >= 0.8,
              metrics.totalTokens >= 250_000,
              metrics.sessionCount >= 3,
              metrics.estimatedCostRatio <= 0.7 else {
            return 0
        }
        var score =
            0.28 * countScore(metrics.tokensPerDollar, baseline?.tokensPerDollar) +
            0.22 * countScore(metrics.messagesPerDollar, baseline?.messagesPerDollar) +
            0.18 * (1.0 - countScore(metrics.costPerSession, baseline?.costPerSession)) +
            0.20 * countScore(Double(metrics.totalTokens), baseline?.totalTokens) +
            0.12 * countScore(Double(metrics.sessionCount), baseline?.sessionCount)
        if hasStrongEfficiencySignature(metrics) {
            score += 0.10
        }
        if hasStrongToolSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongNightSignature(metrics) || hasStrongMultiModelSignature(metrics) {
            score -= 0.16
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.06
        }
        return min(score, 1.2)
    }

    private static func steadyBuilderScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        var score =
            0.30 * ratioScore(metrics.activeDayCoverage, baseline?.activeDayCoverage) +
            0.25 * countScore(Double(metrics.sessionCount), baseline?.sessionCount) +
            0.20 * countScore(Double(metrics.messageCount), baseline?.messageCount) +
            0.15 * countScore(Double(metrics.projectCount), baseline?.projectCount) +
            0.10 * (1.0 - ratioScore(metrics.nightTokenRatio, baseline?.nightTokenRatio))
        if distinctiveSignatureCount(metrics) > 0 {
            score -= 0.10
        }
        if distinctiveSignatureCount(metrics) > 1 {
            score -= 0.08
        }
        return min(score, 1.2)
    }

    private static func longHorizonVibeCodingKingScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        var score =
            0.26 * rangeScore(metrics.toolUsePerMessage, min: 0.16, max: 0.58) +
            0.18 * rangeScore(Double(metrics.toolCategoryCount), min: 3, max: 9) +
            0.16 * rangeScore(Double(metrics.projectCount), min: 4, max: 20) +
            0.16 * rangeScore(Double(metrics.sessionCount), min: 12, max: 180) +
            0.12 * rangeScore(Double(metrics.messageCount), min: 160, max: 8_000) +
            0.12 * rangeScore(metrics.averageTokensPerSession, min: 20_000, max: 260_000)

        score += 0.04 * liftScore(metrics.toolUsePerMessage, baseline?.toolUsePerMessage)

        if metrics.toolUsePerMessage < 0.18 || metrics.toolCategoryCount < 3 {
            score -= 0.18
        }
        if hasStrongNightSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongMultiModelSignature(metrics) {
            score -= 0.14
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.14
        }
        return min(score, 1.2)
    }

    private static func longHorizonFullStackPathfinderScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        var score =
            0.34 * rangeScore(Double(metrics.projectCount), min: 5, max: 26) +
            0.22 * rangeScore(metrics.activeDayCoverage, min: 0.25, max: 0.85) +
            0.16 * rangeScore(Double(metrics.activeDayCount), min: 12, max: 220) +
            0.12 * rangeScore(Double(metrics.toolCategoryCount), min: 3, max: 9) +
            0.10 * rangeScore(Double(metrics.modelCount), min: 2, max: 8) +
            0.06 * liftScore(metrics.projectCount, baseline?.projectCount)

        if metrics.projectCount < 5 {
            score = 0
        }
        if metrics.projectCount >= 10 && metrics.activeDayCount >= 20 {
            score += 0.06
        }
        if hasStrongToolSignature(metrics) || hasStrongNightSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongSprintSignature(metrics) {
            score -= 0.10
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.10
        }
        return min(score, 1.2)
    }

    private static func allTimeVibeCodingKingScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        longHorizonVibeCodingKingScore(metrics: metrics, baseline: baseline)
    }

    private static func allTimeToolSummonerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateToolSignature(metrics) else { return 0 }
        var score =
            0.46 * rangeScore(metrics.toolUsePerMessage, min: 0.20, max: 0.75) +
            0.30 * rangeScore(Double(metrics.toolCategoryCount), min: 3, max: 9) +
            0.12 * rangeScore(Double(metrics.toolUseCount), min: 120, max: 1_800) +
            0.12 * liftScore(metrics.toolUsePerMessage, baseline?.toolUsePerMessage)
        if hasStrongToolSignature(metrics) {
            score += 0.10
        }
        if hasModerateToolSignature(metrics) {
            score += 0.03
        }
        if hasModerateContextSignature(metrics) || hasModerateMultiModelSignature(metrics) || hasModerateNightSignature(metrics) {
            score -= 0.08
        }
        return min(score, 1.2)
    }

    private static func allTimeContextBeastTamerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateContextSignature(metrics) else { return 0 }
        var score =
            0.30 * rangeScore(metrics.averageContextUsagePercent, min: 8, max: 30) +
            0.22 * rangeScore(Double(metrics.cacheReadTokens), min: 80_000, max: 3_000_000) +
            0.22 * rangeScore(metrics.longSessionRatio, min: 0.16, max: 0.6) +
            0.16 * rangeScore(cacheReadRatio(metrics), min: 0.04, max: 0.28) +
            0.06 * rangeScore(metrics.averageTokensPerSession, min: 30_000, max: 450_000) +
            0.04 * liftScore(metrics.averageContextUsagePercent, baseline?.averageContextUsagePercent)
        if hasStrongContextSignature(metrics) {
            score += 0.10
        }
        if hasModerateContextSignature(metrics) {
            score += 0.04
        }
        if hasModerateToolSignature(metrics) || hasModerateMultiModelSignature(metrics) {
            score -= 0.08
        }
        return min(score, 1.2)
    }

    private static func allTimeNightShiftEngineerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateNightSignature(metrics) else { return 0 }
        var score =
            0.45 * rangeScore(metrics.nightTokenRatio, min: 0.18, max: 0.8) +
            0.30 * rangeScore(metrics.nightSessionRatio, min: 0.18, max: 0.8) +
            0.25 * rangeScore(Double(metrics.nightSessionCount), min: 6, max: 80)
        score += 0.10 * liftScore(metrics.nightTokenRatio, baseline?.nightTokenRatio)
        if hasStrongNightSignature(metrics) {
            score += 0.14
        }
        if hasModerateNightSignature(metrics) {
            score += 0.08
        }
        return min(score, 1.2)
    }

    private static func allTimeMultiModelDirectorScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard hasModerateMultiModelSignature(metrics) else { return 0 }
        let adjustedModelCount = providerAdjustedModelCount(metrics)
        let baselineAdjustedModelCount = baseline.map(providerAdjustedModelCount)
        var score =
            0.12 * rangeScore(Double(metrics.providerCount), min: 1, max: 3) +
            0.42 * rangeScore(Double(adjustedModelCount), min: 2, max: 8) +
            0.30 * rangeScore(metrics.modelEntropy, min: 0.34, max: 0.95) +
            0.10 * liftScore(metrics.modelEntropy, baseline?.modelEntropy) +
            0.06 * liftScore(adjustedModelCount, baselineAdjustedModelCount)
        if hasStrongMultiModelSignature(metrics) {
            score += 0.14
        }
        if hasModerateMultiModelSignature(metrics) {
            score += 0.10
        }
        if metrics.providerCount >= 2 && adjustedModelCount < 3 {
            score -= 0.24
        }
        return min(score, 1.2)
    }

    private static func allTimeSprintHackerScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard metrics.peakFiveMinuteTokens >= 120_000 || metrics.singleDayPeakRatio >= 0.24 else { return 0 }
        var score =
            0.42 * rangeScore(metrics.singleDayPeakRatio, min: 0.18, max: 0.65) +
            0.34 * rangeScore(Double(metrics.peakFiveMinuteTokens), min: 120_000, max: 6_000_000) +
            0.24 * rangeScore(Double(metrics.peakDayTokens), min: 300_000, max: 20_000_000)
        score += 0.10 * liftScore(metrics.singleDayPeakRatio, baseline?.singleDayPeakRatio)
        if hasStrongSprintSignature(metrics) {
            score += 0.14
        }
        return min(score, 1.2)
    }

    private static func allTimeFullStackPathfinderScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        longHorizonFullStackPathfinderScore(metrics: metrics, baseline: baseline)
    }

    private static func allTimeEfficientOperatorScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        guard metrics.totalCost >= 4.0,
              metrics.totalTokens >= 1_000_000,
              metrics.sessionCount >= 12,
              metrics.estimatedCostRatio <= 0.78 else {
            return 0
        }
        var score =
            0.24 * rangeScore(metrics.tokensPerDollar, min: 110_000, max: 380_000) +
            0.16 * rangeScore(metrics.messagesPerDollar, min: 8, max: 48) +
            0.16 * inverseRangeScore(metrics.costPerSession, min: 3.0, max: 14) +
            0.24 * rangeScore(Double(metrics.totalTokens), min: 1_000_000, max: 12_000_000) +
            0.12 * rangeScore(Double(metrics.sessionCount), min: 12, max: 160) +
            0.08 * liftScore(metrics.tokensPerDollar, baseline?.tokensPerDollar)
        if hasStrongEfficiencySignature(metrics) {
            score += 0.10
        }
        if hasStrongToolSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongMultiModelSignature(metrics) {
            score -= 0.12
        }
        if moderateDistinctiveSignatureCount(metrics) >= 2 {
            score -= 0.06
        }
        return min(score, 1.2)
    }

    private static func allTimeSteadyBuilderScore(metrics: ShareMetrics, baseline: ShareMetrics?) -> Double {
        var score =
            0.36 * rangeScore(metrics.activeDayCoverage, min: 0.28, max: 0.95) +
            0.22 * rangeScore(Double(metrics.activeDayCount), min: 10, max: 240) +
            0.20 * rangeScore(Double(metrics.sessionCount), min: 10, max: 220) +
            0.12 * rangeScore(Double(metrics.messageCount), min: 120, max: 10_000) +
            0.10 * inverseRangeScore(metrics.singleDayPeakRatio, min: 0.08, max: 0.45)
        score += 0.06 * liftScore(metrics.activeDayCoverage, baseline?.activeDayCoverage)
        if hasStrongToolSignature(metrics) || hasStrongContextSignature(metrics) || hasStrongMultiModelSignature(metrics) || hasStrongSprintSignature(metrics) {
            score -= 0.12
        }
        return min(score, 1.2)
    }

    private static func subtitle(for role: ShareRoleID, metrics: ShareMetrics) -> String {
        let options: [String]
        switch role {
        case .vibeCodingKing:
            options = [
                "share.role.vibeCodingKing.subtitle.1",
                "share.role.vibeCodingKing.subtitle.2",
                "share.role.vibeCodingKing.subtitle.3"
            ]
        case .toolSummoner:
            options = [
                "share.role.toolSummoner.subtitle.1",
                "share.role.toolSummoner.subtitle.2",
                "share.role.toolSummoner.subtitle.3"
            ]
        case .contextBeastTamer:
            options = [
                "share.role.contextBeastTamer.subtitle.1",
                "share.role.contextBeastTamer.subtitle.2",
                "share.role.contextBeastTamer.subtitle.3"
            ]
        case .nightShiftEngineer:
            options = [
                "share.role.nightShiftEngineer.subtitle.1",
                "share.role.nightShiftEngineer.subtitle.2",
                "share.role.nightShiftEngineer.subtitle.3"
            ]
        case .multiModelDirector:
            options = [
                "share.role.multiModelDirector.subtitle.1",
                "share.role.multiModelDirector.subtitle.2",
                "share.role.multiModelDirector.subtitle.3"
            ]
        case .sprintHacker:
            options = [
                "share.role.sprintHacker.subtitle.1",
                "share.role.sprintHacker.subtitle.2",
                "share.role.sprintHacker.subtitle.3"
            ]
        case .fullStackPathfinder:
            options = [
                "share.role.fullStackPathfinder.subtitle.1",
                "share.role.fullStackPathfinder.subtitle.2",
                "share.role.fullStackPathfinder.subtitle.3"
            ]
        case .efficientOperator:
            options = [
                "share.role.efficientOperator.subtitle.1",
                "share.role.efficientOperator.subtitle.2",
                "share.role.efficientOperator.subtitle.3"
            ]
        case .steadyBuilder:
            options = [
                "share.role.steadyBuilder.subtitle.1",
                "share.role.steadyBuilder.subtitle.2",
                "share.role.steadyBuilder.subtitle.3"
            ]
        }
        let key = options[stableIndex(seed: "\(role.rawValue)-\(metrics.scopeLabel)-\(metrics.sessionCount)-\(metrics.totalTokens)", count: options.count)]
        return localized(key)
    }

    private static func summary(for role: ShareRoleID, metrics: ShareMetrics) -> String {
        switch role {
        case .vibeCodingKing:
            return localized("share.role.vibeCodingKing.summary", metrics.projectCount, metrics.toolUseCount, metrics.scopeLabel)
        case .toolSummoner:
            return localized("share.role.toolSummoner.summary", metrics.toolUsePerMessage.formatted(.number.precision(.fractionLength(1))))
        case .contextBeastTamer:
            return localized("share.role.contextBeastTamer.summary", Int(metrics.averageContextUsagePercent))
        case .nightShiftEngineer:
            return localized("share.role.nightShiftEngineer.summary", Int(metrics.nightTokenRatio * 100))
        case .multiModelDirector:
            return localized("share.role.multiModelDirector.summary", metrics.modelCount)
        case .sprintHacker:
            return localized("share.role.sprintHacker.summary", Int(metrics.singleDayPeakRatio * 100))
        case .fullStackPathfinder:
            return localized("share.role.fullStackPathfinder.summary", metrics.projectCount, metrics.activeDayCount)
        case .efficientOperator:
            return localized("share.role.efficientOperator.summary", TimeFormatter.tokenCount(metrics.totalTokens), formatCost(metrics.totalCost))
        case .steadyBuilder:
            return localized("share.role.steadyBuilder.summary")
        }
    }

    private static func providerSummary(for metrics: ShareMetrics) -> String {
        if metrics.providerCount <= 1 {
            return metrics.dominantProvider?.displayName ?? localized("share.provider.unknown")
        }
        let labels = metrics.providerKinds
            .map(\.displayName)
            .sorted()
        return labels.joined(separator: " + ")
    }

    private static func proofMetrics(for role: ShareRoleID, metrics: ShareMetrics) -> [ShareProofMetric] {
        let leading = [
            metric(TimeFormatter.tokenCount(metrics.totalTokens), "share.metric.tokens", "number"),
            metric(formatCost(metrics.totalCost), "share.metric.cost", "dollarsign.circle.fill")
        ]

        switch role {
        case .vibeCodingKing:
            return leading + [
                metric("\(metrics.toolUseCount)", "share.metric.toolCalls", "wrench.and.screwdriver.fill"),
                metric("\(metrics.sessionCount)", "share.metric.sessions", "list.bullet"),
                metric("\(metrics.projectCount)", "share.metric.projects", "folder.fill"),
                metric("\(metrics.activeDayCount)", "share.metric.activeDays", "calendar"),
                metric(metrics.toolUsePerMessage.formatted(.number.precision(.fractionLength(1))), "share.metric.toolsPerMessage", "wand.and.stars"),
                metric("\(metrics.toolCategoryCount)", "share.metric.toolTypes", "square.stack.3d.up.fill")
            ]
        case .toolSummoner:
            return leading + [
                metric("\(metrics.toolUseCount)", "share.metric.toolCalls", "terminal.fill"),
                metric(metrics.toolUsePerMessage.formatted(.number.precision(.fractionLength(1))), "share.metric.toolsPerMessage", "wand.and.stars"),
                metric("\(metrics.toolCategoryCount)", "share.metric.toolTypes", "square.stack.3d.up.fill"),
                metric("\(metrics.sessionCount)", "share.metric.sessions", "list.bullet"),
                metric("\(metrics.projectCount)", "share.metric.projects", "folder.fill"),
                metric("\(metrics.activeDayCount)", "share.metric.activeDays", "calendar")
            ]
        case .contextBeastTamer:
            return leading + [
                metric("\(Int(metrics.averageContextUsagePercent))%", "share.metric.avgContext", "rectangle.stack.fill"),
                metric(TimeFormatter.tokenCount(metrics.cacheReadTokens), "share.metric.cacheRead", "externaldrive.fill.badge.checkmark"),
                metric("\(Int(metrics.longSessionRatio * 100))%", "share.metric.longSessions", "hourglass"),
                metric("\(metrics.sessionCount)", "share.metric.sessions", "list.bullet"),
                metric(TimeFormatter.tokenCount(Int(metrics.averageTokensPerSession)), "share.metric.avgTokensPerSession", "number"),
                metric("\(metrics.activeDayCount)", "share.metric.activeDays", "calendar")
            ]
        case .nightShiftEngineer:
            return leading + [
                metric("\(Int(metrics.nightTokenRatio * 100))%", "share.metric.nightTokens", "moon.fill"),
                metric("\(metrics.nightSessionCount)", "share.metric.nightSessions", "bed.double.fill"),
                metric("\(metrics.activeDayCount)", "share.metric.activeDays", "calendar"),
                metric("\(metrics.sessionCount)", "share.metric.sessions", "list.bullet"),
                metric("\(Int(metrics.nightSessionRatio * 100))%", "share.metric.nightSessionRatio", "moon.zzz.fill"),
                metric(TimeFormatter.tokenCount(Int(metrics.averageTokensPerSession)), "share.metric.avgTokensPerSession", "number")
            ]
        case .multiModelDirector:
            return leading + [
                metric("\(metrics.modelCount)", "share.metric.models", "cpu.fill"),
                metric("\(metrics.providerCount)", "share.metric.providers", "circle.grid.2x2.fill"),
                metric("\(Int(metrics.modelEntropy * 100))%", "share.metric.mixDiversity", "theatermasks.fill"),
                metric("\(metrics.sessionCount)", "share.metric.sessions", "list.bullet"),
                metric("\(metrics.projectCount)", "share.metric.projects", "folder.fill"),
                metric("\(metrics.activeDayCount)", "share.metric.activeDays", "calendar")
            ]
        case .sprintHacker:
            return leading + [
                metric("\(Int(metrics.singleDayPeakRatio * 100))%", "share.metric.peakDayShare", "flame.fill"),
                metric(TimeFormatter.tokenCount(metrics.peakFiveMinuteTokens), "share.metric.peakFiveMinute", "bolt.fill"),
                metric("\(metrics.activeDayCount)", "share.metric.activeDays", "calendar"),
                metric("\(metrics.sessionCount)", "share.metric.sessions", "list.bullet"),
                metric("\(metrics.projectCount)", "share.metric.projects", "folder.fill"),
                metric(TimeFormatter.tokenCount(Int(metrics.averageTokensPerSession)), "share.metric.avgTokensPerSession", "number")
            ]
        case .fullStackPathfinder:
            return leading + [
                metric("\(metrics.projectCount)", "share.metric.projects", "map.fill"),
                metric("\(Int(metrics.activeDayCoverage * 100))%", "share.metric.dayCoverage", "calendar.badge.clock"),
                metric("\(metrics.activeDayCount)", "share.metric.activeDays", "calendar"),
                metric("\(metrics.sessionCount)", "share.metric.sessions", "point.3.connected.trianglepath.dotted"),
                metric("\(metrics.toolUseCount)", "share.metric.toolCalls", "wrench.and.screwdriver.fill"),
                metric("\(metrics.messageCount)", "share.metric.messages", "message.fill")
            ]
        case .efficientOperator:
            return leading + [
                metric(TimeFormatter.tokenCount(Int(metrics.tokensPerDollar)), "share.metric.tokensPerDollar", "chart.line.uptrend.xyaxis"),
                metric(metrics.messagesPerDollar.formatted(.number.precision(.fractionLength(1))), "share.metric.messagesPerDollar", "message.fill"),
                metric(formatCost(metrics.costPerSession), "share.metric.costPerSession", "gauge.with.dots.needle.50percent"),
                metric("\(metrics.sessionCount)", "share.metric.sessions", "list.bullet"),
                metric("\(metrics.projectCount)", "share.metric.projects", "folder.fill"),
                metric("\(metrics.activeDayCount)", "share.metric.activeDays", "calendar")
            ]
        case .steadyBuilder:
            return leading + [
                metric("\(metrics.sessionCount)", "share.metric.sessions", "list.bullet"),
                metric("\(metrics.activeDayCount)", "share.metric.activeDays", "calendar"),
                metric("\(metrics.projectCount)", "share.metric.projects", "folder.fill"),
                metric("\(metrics.messageCount)", "share.metric.messages", "message.fill"),
                metric(TimeFormatter.tokenCount(Int(metrics.averageTokensPerSession)), "share.metric.avgTokensPerSession", "number"),
                metric("\(Int(metrics.activeDayCoverage * 100))%", "share.metric.dayCoverage", "calendar.badge.clock")
            ]
        }
    }

    private static func selectBadges(metrics: ShareMetrics, primaryRole: ShareRoleID) -> [ShareBadge] {
        let targetBadgeCount = 4
        let suppressed = suppressedBadges(for: primaryRole)
        let ranked = ShareBadgeID.allCases
            .filter { !suppressed.contains($0) }
            .map { ($0, badgeScore($0, metrics: metrics) + badgeAffinityBonus($0, primaryRole: primaryRole)) }
            .filter { $0.1 > 0.15 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.rawValue < rhs.0.rawValue
                }
                return lhs.1 > rhs.1
            }

        var selected: [(ShareBadgeID, Double)] = []
        var usedCategories = Set<ShareBadgeCategory>()

        for candidate in ranked {
            if usedCategories.contains(candidate.0.category) { continue }
            selected.append(candidate)
            usedCategories.insert(candidate.0.category)
            if selected.count == targetBadgeCount { break }
        }

        if selected.count < targetBadgeCount {
            for candidate in ranked where !selected.contains(where: { $0.0 == candidate.0 }) {
                selected.append(candidate)
                if selected.count == targetBadgeCount { break }
            }
        }

        return selected.map { badge, _ in
            ShareBadge(id: badge, title: badge.title, symbolName: badge.symbolName, tint: badge.tint)
        }
    }

    private static func suppressedBadges(for role: ShareRoleID) -> Set<ShareBadgeID> {
        switch role {
        case .nightShiftEngineer:
            return [.nightOwl]
        case .toolSummoner:
            return [.toolAddict]
        case .contextBeastTamer:
            return [.cacheWizard]
        case .sprintHacker:
            return [.peakDayMonster]
        case .efficientOperator:
            return []
        default:
            return []
        }
    }

    private static func badgeScore(_ badge: ShareBadgeID, metrics: ShareMetrics) -> Double {
        switch badge {
        case .nightOwl:
            return metrics.nightTokenRatio
        case .cacheWizard:
            return min(Double(metrics.cacheReadTokens) / 250_000.0, 1.0)
        case .opusLoyalist:
            return metrics.modelShare(containing: "opus")
        case .sonnetSpecialist:
            return metrics.modelShare(containing: "sonnet")
        case .geminiFlashRunner:
            return max(metrics.modelShare(containing: "flash"), metrics.modelShare(containing: "gemini-2.0-flash"))
        case .toolAddict:
            return min(metrics.toolUsePerMessage / 1.2, 1.0)
        case .projectHopper:
            return min(Double(metrics.projectCount) / 6.0, 1.0)
        case .consistencyMachine:
            return metrics.activeDayCoverage
        case .costMinimalist:
            guard metrics.totalCost > 0 else { return 0 }
            return min(metrics.tokensPerDollar / 200_000.0, 1.0)
        case .peakDayMonster:
            return metrics.scope == .daily
                ? min((metrics.totalTokens > 0 ? Double(metrics.peakFiveMinuteTokens) / Double(metrics.totalTokens) : 0) / 0.5, 1.0)
                : metrics.singleDayPeakRatio
        case .throughputBeast:
            return max(
                min(Double(metrics.totalTokens) / 2_000_000.0, 1.0),
                min(metrics.averageTokensPerSession / 180_000.0, 1.0)
            )
        }
    }

    private static func badgeAffinityBonus(_ badge: ShareBadgeID, primaryRole: ShareRoleID) -> Double {
        switch primaryRole {
        case .vibeCodingKing:
            switch badge {
            case .toolAddict, .projectHopper, .throughputBeast: return 0.08
            default: return 0
            }
        case .toolSummoner:
            switch badge {
            case .toolAddict, .cacheWizard, .projectHopper: return 0.08
            default: return 0
            }
        case .contextBeastTamer:
            switch badge {
            case .cacheWizard, .throughputBeast, .opusLoyalist, .sonnetSpecialist: return 0.08
            default: return 0
            }
        case .nightShiftEngineer:
            switch badge {
            case .nightOwl, .peakDayMonster, .throughputBeast: return 0.08
            default: return 0
            }
        case .multiModelDirector:
            switch badge {
            case .opusLoyalist, .sonnetSpecialist, .geminiFlashRunner: return 0.08
            default: return 0
            }
        case .sprintHacker:
            switch badge {
            case .peakDayMonster, .throughputBeast, .toolAddict: return 0.08
            default: return 0
            }
        case .fullStackPathfinder:
            switch badge {
            case .projectHopper, .toolAddict, .consistencyMachine: return 0.08
            default: return 0
            }
        case .efficientOperator:
            switch badge {
            case .costMinimalist, .throughputBeast, .consistencyMachine: return 0.08
            default: return 0
            }
        case .steadyBuilder:
            switch badge {
            case .consistencyMachine, .projectHopper, .costMinimalist: return 0.08
            default: return 0
            }
        }
    }

    private static func metric(_ value: String, _ label: String, _ symbol: String) -> ShareProofMetric {
        ShareProofMetric(value: value, label: localized(label), symbolName: symbol)
    }

    private static func countScore(_ current: Double, _ baseline: Int?) -> Double {
        countScore(current, baseline.map(Double.init))
    }

    private static func countScore(_ current: Double, _ baseline: Double?) -> Double {
        guard current > 0 else { return 0 }
        let base = baseline ?? 0
        let currentTerm = current / (current + max(base, 1) + 4)
        let liftTerm: Double
        if base > 0 {
            liftTerm = min(max((current - base) / max(base, 1), 0), 1)
        } else {
            liftTerm = min(current / 8.0, 1.0)
        }
        return clamp((0.65 * currentTerm) + (0.35 * liftTerm))
    }

    private static func ratioScore(_ current: Double, _ baseline: Double?) -> Double {
        let clipped = clamp(current)
        let base = clamp(baseline ?? 0)
        let lift: Double
        if clipped > base {
            lift = (clipped - base) / max(1 - base, 0.15)
        } else {
            lift = 0
        }
        return clamp((0.65 * clipped) + (0.35 * lift))
    }

    private static func rangeScore(_ current: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        guard upperBound > lowerBound else { return clamp(current) }
        return clamp((current - lowerBound) / (upperBound - lowerBound))
    }

    private static func inverseRangeScore(_ current: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        1.0 - rangeScore(current, min: lowerBound, max: upperBound)
    }

    private static func liftScore(_ current: Int, _ baseline: Int?) -> Double {
        liftScore(Double(current), baseline.map(Double.init))
    }

    private static func liftScore(_ current: Double, _ baseline: Double?) -> Double {
        guard current > 0 else { return 0 }
        guard let baseline, baseline > 0 else { return clamp(current / max(current + 1, 8)) }
        return clamp((current - baseline) / max(baseline, 1))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func formatCost(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.2f", cost) }
        if cost >= 0.01 { return String(format: "$%.3f", cost) }
        return String(format: "$%.4f", cost)
    }

    private static func stableIndex(seed: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var total = 0
        for scalar in seed.unicodeScalars {
            total = ((total * 31) + Int(scalar.value)) % 2_147_483_647
        }
        return total % count
    }

    private static func localized(_ key: String, _ args: CVarArg...) -> String {
        let format = LanguageManager.localizedString(key)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: LanguageManager.currentLocale, arguments: args)
    }

    private static func specialistPreferred(over primary: ShareRoleID, candidate: ShareRoleID, score: Double, metrics: ShareMetrics) -> Bool {
        guard candidate != primary, candidate != .steadyBuilder else { return false }
        guard score >= 0.4 else { return false }

        switch candidate {
        case .toolSummoner:
            return hasStrongToolSignature(metrics)
        case .contextBeastTamer:
            return hasStrongContextSignature(metrics)
        case .nightShiftEngineer:
            return hasStrongNightSignature(metrics)
        case .multiModelDirector:
            return hasStrongMultiModelSignature(metrics)
        case .sprintHacker:
            return hasStrongSprintSignature(metrics)
        case .efficientOperator:
            return hasStrongEfficiencySignature(metrics) && score >= 0.56
        default:
            return false
        }
    }

    private static func identitySpecialistCandidate(
        from ranked: [ShareRoleScore],
        top: ShareRoleScore,
        metrics: ShareMetrics,
        minimumScore: Double,
        maximumGap: Double
    ) -> ShareRoleScore? {
        ranked.first { candidate in
            guard specialistRoleIDs.contains(candidate.roleID) else { return false }
            guard candidate.score >= minimumScore else { return false }
            guard top.score - candidate.score <= maximumGap else { return false }
            return specialistPreferred(over: top.roleID, candidate: candidate.roleID, score: candidate.score, metrics: metrics)
        }
    }

    private static func genericSpecialistMinimumScore(for scope: StatsPeriod, topRole: ShareRoleID) -> Double {
        switch scope {
        case .daily:
            return topRole == .steadyBuilder ? 0.40 : 0.44
        case .weekly:
            return topRole == .steadyBuilder ? 0.42 : 0.46
        case .monthly:
            return topRole == .steadyBuilder ? 0.42 : 0.44
        case .yearly:
            return 0.40
        }
    }

    private static func genericSpecialistMaximumGap(for scope: StatsPeriod, topRole: ShareRoleID) -> Double {
        switch scope {
        case .daily:
            return topRole == .steadyBuilder ? 0.18 : 0.14
        case .weekly:
            return topRole == .steadyBuilder ? 0.16 : 0.12
        case .monthly:
            return topRole == .steadyBuilder ? 0.18 : 0.16
        case .yearly:
            return 0.20
        }
    }

    private static func distinctiveSignatureCount(_ metrics: ShareMetrics) -> Int {
        [
            hasStrongToolSignature(metrics),
            hasStrongContextSignature(metrics),
            hasStrongNightSignature(metrics),
            hasStrongMultiModelSignature(metrics),
            hasStrongSprintSignature(metrics),
            hasStrongEfficiencySignature(metrics)
        ]
        .filter { $0 }
        .count
    }

    private static func moderateDistinctiveSignatureCount(_ metrics: ShareMetrics) -> Int {
        [
            hasModerateToolSignature(metrics),
            hasModerateContextSignature(metrics),
            hasModerateNightSignature(metrics),
            hasModerateMultiModelSignature(metrics),
            hasStrongSprintSignature(metrics),
            hasStrongEfficiencySignature(metrics)
        ]
        .filter { $0 }
        .count
    }

    private static var specialistRoleIDs: Set<ShareRoleID> {
        [.toolSummoner, .contextBeastTamer, .nightShiftEngineer, .multiModelDirector, .sprintHacker, .efficientOperator]
    }

    private static var genericRoleIDs: Set<ShareRoleID> {
        [.vibeCodingKing, .fullStackPathfinder, .steadyBuilder]
    }

    private static func hasModerateToolSignature(_ metrics: ShareMetrics) -> Bool {
        switch metrics.scope {
        case .daily:
            return metrics.toolUseCount >= 5 && metrics.toolUsePerMessage >= 0.18 && metrics.toolCategoryCount >= 2
        case .weekly:
            return metrics.toolUseCount >= 10 && metrics.toolUsePerMessage >= 0.18 && metrics.toolCategoryCount >= 2
        case .monthly, .yearly:
            return metrics.toolUseCount >= 36 && metrics.toolUsePerMessage >= 0.22 && metrics.toolCategoryCount >= 3
        }
    }

    private static func hasStrongToolSignature(_ metrics: ShareMetrics) -> Bool {
        switch metrics.scope {
        case .daily:
            return metrics.toolUseCount >= 8 && metrics.toolUsePerMessage >= 0.28 && metrics.toolCategoryCount >= 2
        case .weekly:
            return metrics.toolUseCount >= 18 && metrics.toolUsePerMessage >= 0.26 && metrics.toolCategoryCount >= 3
        case .monthly, .yearly:
            return metrics.toolUseCount >= 72 && metrics.toolUsePerMessage >= 0.32 && metrics.toolCategoryCount >= 4
        }
    }

    private static func hasModerateContextSignature(_ metrics: ShareMetrics) -> Bool {
        let signalCount = contextSignalCount(metrics, strong: false)
        switch metrics.scope {
        case .daily:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 18 || cacheReadRatio(metrics) >= 0.24
        case .weekly:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 20 || cacheReadRatio(metrics) >= 0.26
        case .monthly, .yearly:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 22 || cacheReadRatio(metrics) >= 0.28
        }
    }

    private static func hasStrongContextSignature(_ metrics: ShareMetrics) -> Bool {
        let signalCount = contextSignalCount(metrics, strong: true)
        switch metrics.scope {
        case .daily:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 24 || cacheReadRatio(metrics) >= 0.32
        case .weekly:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 26 || cacheReadRatio(metrics) >= 0.34
        case .monthly, .yearly:
            return signalCount >= 2 || metrics.averageContextUsagePercent >= 28 || cacheReadRatio(metrics) >= 0.36
        }
    }

    private static func contextSignalCount(_ metrics: ShareMetrics, strong: Bool) -> Int {
        let cacheRatio = cacheReadRatio(metrics)
        let averageContextThreshold: Double
        let cacheTokenThreshold: Int
        let cacheRatioThreshold: Double
        let longSessionThreshold: Double
        let averageTokensThreshold: Double

        switch (metrics.scope, strong) {
        case (.daily, false):
            averageContextThreshold = 8
            cacheTokenThreshold = 60_000
            cacheRatioThreshold = 0.10
            longSessionThreshold = 0.25
            averageTokensThreshold = 60_000
        case (.daily, true):
            averageContextThreshold = 14
            cacheTokenThreshold = 140_000
            cacheRatioThreshold = 0.18
            longSessionThreshold = 0.40
            averageTokensThreshold = 140_000
        case (.weekly, false):
            averageContextThreshold = 9
            cacheTokenThreshold = 100_000
            cacheRatioThreshold = 0.08
            longSessionThreshold = 0.24
            averageTokensThreshold = 70_000
        case (.weekly, true):
            averageContextThreshold = 15
            cacheTokenThreshold = 220_000
            cacheRatioThreshold = 0.16
            longSessionThreshold = 0.38
            averageTokensThreshold = 160_000
        case (.monthly, false), (.yearly, false):
            averageContextThreshold = 10
            cacheTokenThreshold = 180_000
            cacheRatioThreshold = 0.07
            longSessionThreshold = 0.22
            averageTokensThreshold = 80_000
        case (.monthly, true), (.yearly, true):
            averageContextThreshold = 16
            cacheTokenThreshold = 360_000
            cacheRatioThreshold = 0.14
            longSessionThreshold = 0.36
            averageTokensThreshold = 180_000
        }

        return [
            metrics.averageContextUsagePercent >= averageContextThreshold,
            metrics.cacheReadTokens >= cacheTokenThreshold,
            cacheRatio >= cacheRatioThreshold,
            metrics.longSessionRatio >= longSessionThreshold,
            metrics.averageTokensPerSession >= averageTokensThreshold
        ]
        .filter { $0 }
        .count
    }

    private static func hasModerateNightSignature(_ metrics: ShareMetrics) -> Bool {
        switch metrics.scope {
        case .daily:
            return metrics.nightTokenRatio >= 0.32 && metrics.nightSessionCount >= 1
        case .weekly:
            return metrics.nightTokenRatio >= 0.24 && metrics.nightSessionCount >= 2
        case .monthly, .yearly:
            return metrics.nightTokenRatio >= 0.22 && metrics.nightSessionCount >= 3
        }
    }

    private static func hasStrongNightSignature(_ metrics: ShareMetrics) -> Bool {
        switch metrics.scope {
        case .daily:
            return metrics.nightTokenRatio >= 0.5 && metrics.nightSessionCount >= 1
        case .weekly:
            return metrics.nightTokenRatio >= 0.32 && metrics.nightSessionCount >= 2
        case .monthly, .yearly:
            return metrics.nightTokenRatio >= 0.3 && metrics.nightSessionCount >= 4
        }
    }

    private static func hasModerateMultiModelSignature(_ metrics: ShareMetrics) -> Bool {
        let adjustedModelCount = providerAdjustedModelCount(metrics)
        if metrics.providerCount >= 2 {
            return adjustedModelCount >= 3 && metrics.modelEntropy >= 0.34
        }
        return metrics.modelCount >= 2 && metrics.modelEntropy >= 0.30
    }

    private static func hasStrongMultiModelSignature(_ metrics: ShareMetrics) -> Bool {
        let adjustedModelCount = providerAdjustedModelCount(metrics)
        if metrics.providerCount >= 2 {
            return adjustedModelCount >= 5 && metrics.modelEntropy >= 0.50
        }
        return metrics.modelCount >= 2 && metrics.modelEntropy >= 0.45
    }

    private static func providerAdjustedModelCount(_ metrics: ShareMetrics) -> Int {
        // Multi-provider cards naturally contain one or more models per provider. Count only
        // model variety beyond the provider split so "All AI" does not default to this role.
        max(0, metrics.modelCount - max(metrics.providerCount - 1, 0))
    }

    private static func cacheReadRatio(_ metrics: ShareMetrics) -> Double {
        guard metrics.totalTokens > 0 else { return 0 }
        return Double(metrics.cacheReadTokens) / Double(metrics.totalTokens)
    }

    private static func hasStrongSprintSignature(_ metrics: ShareMetrics) -> Bool {
        if metrics.scope == .daily { return false }
        return metrics.singleDayPeakRatio >= 0.4 || metrics.peakFiveMinuteTokens >= 80_000
    }

    private static func hasStrongEfficiencySignature(_ metrics: ShareMetrics) -> Bool {
        switch metrics.scope {
        case .daily:
            return metrics.totalTokens >= 400_000 &&
                metrics.totalCost >= 1.2 &&
                metrics.tokensPerDollar >= 220_000 &&
                metrics.messagesPerDollar >= 10
        case .weekly, .monthly, .yearly:
            return metrics.totalTokens >= 500_000 &&
                metrics.totalCost >= 1.0 &&
                metrics.tokensPerDollar >= 220_000 &&
                metrics.messagesPerDollar >= 10 &&
                metrics.averageTokensPerSession >= 20_000
        }
    }
}
