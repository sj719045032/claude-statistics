import ClaudeStatisticsKit
import Foundation

enum ShareRoleEngine {
    /// Plugin-contributed scores merge into the ranked list as a final
    /// step. They participate in `choosePrimaryRole` selection just
    /// like builtin scores, so a plugin role with a high enough score
    /// can win the card. The host clamps each score to `[0, 1]` and
    /// silently drops entries whose `roleID` is empty.
    static func makeRoleResult(
        metrics: ShareMetrics,
        baseline: ShareMetrics?,
        pluginScores: [ShareRoleScoreEntry] = []
    ) -> ShareRoleResult {
        let ranked = mergePluginScores(into: rankedRoles(metrics: metrics, baseline: baseline), pluginScores: pluginScores)
        let primary = choosePrimaryRole(from: ranked, metrics: metrics)
        return buildRoleResult(primary: primary, ranked: ranked, metrics: metrics)
    }

    static func makeAllTimeRoleResult(
        metrics: ShareMetrics,
        baseline: ShareMetrics?,
        pluginScores: [ShareRoleScoreEntry] = []
    ) -> ShareRoleResult {
        let ranked = mergePluginScores(into: rankedAllTimeRoles(metrics: metrics, baseline: baseline), pluginScores: pluginScores)
        let primary = chooseAllTimePrimaryRole(from: ranked, metrics: metrics)
        return buildRoleResult(primary: primary, ranked: ranked, metrics: metrics)
    }

    /// Append plugin scores to the host-computed ranking, then re-sort.
    /// Empty plugin scores leave the input untouched (zero-cost path).
    private static func mergePluginScores(
        into hostRanked: [ShareRoleScore],
        pluginScores: [ShareRoleScoreEntry]
    ) -> [ShareRoleScore] {
        guard !pluginScores.isEmpty else { return hostRanked }
        let existingIDs = Set(hostRanked.map(\.roleID))
        let pluginEntries = pluginScores.compactMap { entry -> ShareRoleScore? in
            guard let id = ShareRoleID(rawValue: entry.roleID) else { return nil }
            // Plugin can't override a builtin id — silently drop the
            // collision so a misconfigured plugin can't hijack the
            // ranking. Plugins should namespace ids reverse-DNS style.
            guard !existingIDs.contains(id) else { return nil }
            let clamped = min(max(entry.score, 0), 1)
            return ShareRoleScore(roleID: id, score: clamped)
        }
        guard !pluginEntries.isEmpty else { return hostRanked }
        return (hostRanked + pluginEntries).sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.roleID.rawValue < rhs.roleID.rawValue
            }
            return lhs.score > rhs.score
        }
    }

    static func buildRoleResult(primary: ShareRoleID, ranked: [ShareRoleScore], metrics: ShareMetrics) -> ShareRoleResult {
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

    static func rankedRoles(metrics: ShareMetrics, baseline: ShareMetrics?) -> [ShareRoleScore] {
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

    static func rankedAllTimeRoles(metrics: ShareMetrics, baseline: ShareMetrics?) -> [ShareRoleScore] {
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

    static func choosePrimaryRole(from ranked: [ShareRoleScore], metrics: ShareMetrics) -> ShareRoleID {
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

    static func chooseAllTimePrimaryRole(from ranked: [ShareRoleScore], metrics: ShareMetrics) -> ShareRoleID {
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

    // MARK: - Role scoring — moved to ShareRoleEngine+Scoring.swift

    // MARK: - Subtitle / Summary — moved to ShareRoleEngine+Formatting.swift

    // MARK: - Badge selection — moved to ShareRoleEngine+Badges.swift

    static func metric(_ value: String, _ label: String, _ symbol: String) -> ShareProofMetric {
        ShareProofMetric(value: value, label: localized(label), symbolName: symbol)
    }

    static func countScore(_ current: Double, _ baseline: Int?) -> Double {
        countScore(current, baseline.map(Double.init))
    }

    static func countScore(_ current: Double, _ baseline: Double?) -> Double {
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

    static func ratioScore(_ current: Double, _ baseline: Double?) -> Double {
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

    static func rangeScore(_ current: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        guard upperBound > lowerBound else { return clamp(current) }
        return clamp((current - lowerBound) / (upperBound - lowerBound))
    }

    static func inverseRangeScore(_ current: Double, min lowerBound: Double, max upperBound: Double) -> Double {
        1.0 - rangeScore(current, min: lowerBound, max: upperBound)
    }

    static func liftScore(_ current: Int, _ baseline: Int?) -> Double {
        liftScore(Double(current), baseline.map(Double.init))
    }

    static func liftScore(_ current: Double, _ baseline: Double?) -> Double {
        guard current > 0 else { return 0 }
        guard let baseline, baseline > 0 else { return clamp(current / max(current + 1, 8)) }
        return clamp((current - baseline) / max(baseline, 1))
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    static func formatCost(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.2f", cost) }
        if cost >= 0.01 { return String(format: "$%.3f", cost) }
        return String(format: "$%.4f", cost)
    }

    static func stableIndex(seed: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var total = 0
        for scalar in seed.unicodeScalars {
            total = ((total * 31) + Int(scalar.value)) % 2_147_483_647
        }
        return total % count
    }

    static func localized(_ key: String, _ args: CVarArg...) -> String {
        let format = LanguageManager.localizedString(key)
        guard !args.isEmpty else { return format }
        return String(format: format, locale: LanguageManager.currentLocale, arguments: args)
    }

    static func specialistPreferred(over primary: ShareRoleID, candidate: ShareRoleID, score: Double, metrics: ShareMetrics) -> Bool {
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

    static func identitySpecialistCandidate(
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

    static func genericSpecialistMinimumScore(for scope: StatsPeriod, topRole: ShareRoleID) -> Double {
        switch scope {
        case .daily:
            return topRole == .steadyBuilder ? 0.40 : 0.44
        case .weekly:
            return topRole == .steadyBuilder ? 0.42 : 0.46
        case .monthly:
            return topRole == .steadyBuilder ? 0.42 : 0.44
        case .all:
            return 0.40
        }
    }

    static func genericSpecialistMaximumGap(for scope: StatsPeriod, topRole: ShareRoleID) -> Double {
        switch scope {
        case .daily:
            return topRole == .steadyBuilder ? 0.18 : 0.14
        case .weekly:
            return topRole == .steadyBuilder ? 0.16 : 0.12
        case .monthly:
            return topRole == .steadyBuilder ? 0.18 : 0.16
        case .all:
            return 0.20
        }
    }

    static func distinctiveSignatureCount(_ metrics: ShareMetrics) -> Int {
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

    static func moderateDistinctiveSignatureCount(_ metrics: ShareMetrics) -> Int {
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

    // MARK: - Signature heuristics — moved to ShareRoleEngine+Signatures.swift
}
