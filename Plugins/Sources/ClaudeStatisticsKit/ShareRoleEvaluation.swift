import Foundation

/// Aggregate metrics handed to a `ShareRolePlugin` so it can compute
/// scores for the roles it contributes. The host fills this from its
/// internal `ShareMetrics` value at share time; plugins receive a
/// frozen snapshot — primitives + dictionaries — so the type can live
/// in the SDK without dragging the host's private aggregation code.
///
/// Scope is encoded as a string (`"daily"` / `"weekly"` / `"monthly"`
/// / `"all"`) instead of a typed enum so the protocol remains
/// version-tolerant: adding a new scope on the host side doesn't
/// invalidate plugins that only know the existing four values.
public struct ShareRoleEvaluationContext: Sendable {
    public let scope: String
    public let scopeLabel: String
    public let sessionCount: Int
    public let messageCount: Int
    public let totalTokens: Int
    public let totalCost: Double
    public let projectCount: Int
    public let toolUseCount: Int
    public let toolCategoryCount: Int
    public let activeDayCount: Int
    public let totalDayCount: Int
    public let nightSessionCount: Int
    public let nightTokenCount: Int
    public let cacheReadTokens: Int
    public let averageContextUsagePercent: Double
    public let averageTokensPerSession: Double
    public let averageMessagesPerSession: Double
    public let longSessionCount: Int
    public let modelCount: Int
    public let modelEntropy: Double
    public let peakDayTokens: Int
    public let peakFiveMinuteTokens: Int
    public let estimatedCostSessionCount: Int
    public let providerCount: Int
    public let dominantProviderID: String?
    public let providerSessionCounts: [String: Int]
    public let providerTokenCounts: [String: Int]
    public let toolUseCounts: [String: Int]
    public let modelTokenBreakdown: [String: Int]
    /// Same shape as `ShareRoleEvaluationContext` but for the previous
    /// equivalent period. `nil` when no comparable baseline exists
    /// (fresh install, all-time scope, etc.). Plugins can use this to
    /// score "lift" — change vs. last week / last month / last day.
    public let baseline: Baseline?

    public struct Baseline: Sendable {
        public let sessionCount: Int
        public let messageCount: Int
        public let totalTokens: Int
        public let totalCost: Double
        public let toolUseCount: Int
        public let activeDayCount: Int
        public let nightTokenCount: Int

        public init(
            sessionCount: Int,
            messageCount: Int,
            totalTokens: Int,
            totalCost: Double,
            toolUseCount: Int,
            activeDayCount: Int,
            nightTokenCount: Int
        ) {
            self.sessionCount = sessionCount
            self.messageCount = messageCount
            self.totalTokens = totalTokens
            self.totalCost = totalCost
            self.toolUseCount = toolUseCount
            self.activeDayCount = activeDayCount
            self.nightTokenCount = nightTokenCount
        }
    }

    public init(
        scope: String,
        scopeLabel: String,
        sessionCount: Int,
        messageCount: Int,
        totalTokens: Int,
        totalCost: Double,
        projectCount: Int,
        toolUseCount: Int,
        toolCategoryCount: Int,
        activeDayCount: Int,
        totalDayCount: Int,
        nightSessionCount: Int,
        nightTokenCount: Int,
        cacheReadTokens: Int,
        averageContextUsagePercent: Double,
        averageTokensPerSession: Double,
        averageMessagesPerSession: Double,
        longSessionCount: Int,
        modelCount: Int,
        modelEntropy: Double,
        peakDayTokens: Int,
        peakFiveMinuteTokens: Int,
        estimatedCostSessionCount: Int,
        providerCount: Int,
        dominantProviderID: String?,
        providerSessionCounts: [String: Int],
        providerTokenCounts: [String: Int],
        toolUseCounts: [String: Int],
        modelTokenBreakdown: [String: Int],
        baseline: Baseline?
    ) {
        self.scope = scope
        self.scopeLabel = scopeLabel
        self.sessionCount = sessionCount
        self.messageCount = messageCount
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.projectCount = projectCount
        self.toolUseCount = toolUseCount
        self.toolCategoryCount = toolCategoryCount
        self.activeDayCount = activeDayCount
        self.totalDayCount = totalDayCount
        self.nightSessionCount = nightSessionCount
        self.nightTokenCount = nightTokenCount
        self.cacheReadTokens = cacheReadTokens
        self.averageContextUsagePercent = averageContextUsagePercent
        self.averageTokensPerSession = averageTokensPerSession
        self.averageMessagesPerSession = averageMessagesPerSession
        self.longSessionCount = longSessionCount
        self.modelCount = modelCount
        self.modelEntropy = modelEntropy
        self.peakDayTokens = peakDayTokens
        self.peakFiveMinuteTokens = peakFiveMinuteTokens
        self.estimatedCostSessionCount = estimatedCostSessionCount
        self.providerCount = providerCount
        self.dominantProviderID = dominantProviderID
        self.providerSessionCounts = providerSessionCounts
        self.providerTokenCounts = providerTokenCounts
        self.toolUseCounts = toolUseCounts
        self.modelTokenBreakdown = modelTokenBreakdown
        self.baseline = baseline
    }

    public var nightTokenRatio: Double {
        totalTokens > 0 ? Double(nightTokenCount) / Double(totalTokens) : 0
    }

    public var nightSessionRatio: Double {
        sessionCount > 0 ? Double(nightSessionCount) / Double(sessionCount) : 0
    }

    public var toolUsePerMessage: Double {
        messageCount > 0 ? Double(toolUseCount) / Double(messageCount) : 0
    }

    public var activeDayCoverage: Double {
        totalDayCount > 0 ? Double(activeDayCount) / Double(totalDayCount) : 0
    }
}

/// One score entry returned by `ShareRolePlugin.evaluate(context:)`.
/// `roleID` matches a `ShareRoleDescriptor.id` the plugin previously
/// declared in `roles`. Scores outside `[0, 1]` are clamped by the
/// host before merging with builtin scores.
public struct ShareRoleScoreEntry: Sendable, Hashable {
    public let roleID: String
    public let score: Double

    public init(roleID: String, score: Double) {
        self.roleID = roleID
        self.score = score
    }
}
