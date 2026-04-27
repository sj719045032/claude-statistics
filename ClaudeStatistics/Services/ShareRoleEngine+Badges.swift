import Foundation

// MARK: - Badge Selection

extension ShareRoleEngine {
    static func selectBadges(metrics: ShareMetrics, primaryRole: ShareRoleID) -> [ShareBadge] {
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

    static func suppressedBadges(for role: ShareRoleID) -> Set<ShareBadgeID> {
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

    static func badgeScore(_ badge: ShareBadgeID, metrics: ShareMetrics) -> Double {
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

    static func badgeAffinityBonus(_ badge: ShareBadgeID, primaryRole: ShareRoleID) -> Double {
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
        default:
            // Plugin role: no host-side affinity table; let the plugin's
            // own scoring carry the weighting.
            return 0
        }
    }
}
