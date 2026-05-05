import Foundation
import ClaudeStatisticsKit

/// Outcome of running a provider parser against a session file with retry-on-suspect.
///
/// `committedStats` is what should be persisted to the cache (nil = keep last
/// committed value). `displayStats` is what the UI should show right now (may
/// fall back to a cached previous parse when the new one looks suspicious).
struct SessionParseOutcome {
    let sessionId: String
    let committedStats: SessionStats?
    let displayStats: SessionStats?
    let searchMessages: [SearchIndexMessage]
    let shouldRetry: Bool
}

/// Stateless validator that runs `SessionProvider.parseSession` once, sanity-checks
/// the result against the lightweight `SessionQuickStats`, and retries once if the
/// full parse looks suspicious. On a second failure, returns the last cached value
/// so the UI doesn't flash zeros for a transient I/O race.
enum SessionParseValidator {
    static func parse(
        provider: any SessionProvider,
        session: Session,
        quick: SessionQuickStats,
        cached: DatabaseService.CachedSession?
    ) async -> SessionParseOutcome {
        // PR6: combined parse + FTS extract — one file IO, one decode
        // pass per pass through the validator.
        let firstResult = provider.parseSessionAndSearchIndex(at: session.filePath)
        let firstStats = firstResult.stats
        if suspiciousReason(stats: firstStats, quick: quick, session: session) == nil {
            return SessionParseOutcome(
                sessionId: session.id,
                committedStats: firstStats,
                displayStats: firstStats,
                searchMessages: firstResult.searchMessages,
                shouldRetry: false
            )
        }

        let firstReason = suspiciousReason(stats: firstStats, quick: quick, session: session) ?? "suspicious parse result"
        DiagnosticLogger.shared.warning("Suspicious \(provider.kind.rawValue) parse for \(session.id); retrying once (\(firstReason))")
        try? await Task.sleep(nanoseconds: 300_000_000)

        let retryResult = provider.parseSessionAndSearchIndex(at: session.filePath)
        let retryStats = retryResult.stats
        if suspiciousReason(stats: retryStats, quick: quick, session: session) == nil {
            DiagnosticLogger.shared.info("Recovered \(provider.kind.rawValue) parse for \(session.id) after retry")
            return SessionParseOutcome(
                sessionId: session.id,
                committedStats: retryStats,
                displayStats: retryStats,
                searchMessages: retryResult.searchMessages,
                shouldRetry: false
            )
        }

        let retryReason = suspiciousReason(stats: retryStats, quick: quick, session: session) ?? firstReason
        DiagnosticLogger.shared.warning("Rejected \(provider.kind.rawValue) parse for \(session.id); keeping last committed cache (\(retryReason))")
        return SessionParseOutcome(
            sessionId: session.id,
            committedStats: nil,
            displayStats: cached?.sessionStats,
            searchMessages: [],
            shouldRetry: true
        )
    }

    static func suspiciousReason(
        stats: SessionStats,
        quick: SessionQuickStats,
        session: Session
    ) -> String? {
        if let start = stats.startTime, let end = stats.endTime, end < start {
            return "endTime earlier than startTime"
        }
        if quick.messageCount > 0 && stats.messageCount == 0 {
            return "quick messages=\(quick.messageCount), full messages=0"
        }
        if quick.userMessageCount > 0 && stats.userMessageCount == 0 {
            return "quick user messages=\(quick.userMessageCount), full user messages=0"
        }
        if quick.totalTokens > 0 && stats.totalTokens == 0 {
            return "quick tokens=\(quick.totalTokens), full tokens=0"
        }
        let sessionLooksNonEmpty = quick.startTime != nil || quick.messageCount > 0 || quick.totalTokens > 0
        if session.fileSize >= 4_096 &&
            sessionLooksNonEmpty &&
            stats.startTime == nil &&
            stats.endTime == nil &&
            stats.messageCount == 0 &&
            stats.totalTokens == 0 {
            return "empty full stats for non-empty session"
        }
        if stats.messageCount == 0 && (stats.userMessageCount > 0 || stats.assistantMessageCount > 0) {
            return "message counters exist without time slices"
        }
        return nil
    }
}
