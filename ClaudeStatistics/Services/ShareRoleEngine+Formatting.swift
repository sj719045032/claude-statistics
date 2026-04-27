import Foundation

// MARK: - Subtitle / Summary / Proof Metrics

extension ShareRoleEngine {
    static func subtitle(for role: ShareRoleID, metrics: ShareMetrics) -> String {
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

    static func summary(for role: ShareRoleID, metrics: ShareMetrics) -> String {
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

    static func providerSummary(for metrics: ShareMetrics) -> String {
        if metrics.providerCount <= 1 {
            return metrics.dominantProvider?.descriptor.displayName ?? localized("share.provider.unknown")
        }
        let labels = metrics.providerKinds
            .map { $0.descriptor.displayName }
            .sorted()
        return labels.joined(separator: " + ")
    }

    static func proofMetrics(for role: ShareRoleID, metrics: ShareMetrics) -> [ShareProofMetric] {
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
}
