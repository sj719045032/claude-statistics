import Foundation
import ClaudeStatisticsKit

/// Outcome of running a provider parser against a session file with retry-on-suspect.
///
/// `committedStats` is what should be persisted to the cache (nil = keep last
/// committed value). `displayStats` is what the UI should show right now (may
/// fall back to a cached previous parse when the new one looks suspicious).
struct SessionParseOutcome: Sendable {
    let sessionId: String
    let committedStats: SessionStats?
    let displayStats: SessionStats?
    let searchMessages: [SearchIndexMessage]
    let shouldRetry: Bool
    var checkpointUpdate: CheckpointedSessionUpdate? = nil
    var expectedCheckpointID: UUID? = nil

    func saveRequest(for session: Session, quick: SessionQuickStats? = nil) -> DatabaseService.SaveSessionStatsRequest? {
        guard let stats = committedStats else { return nil }
        if let update = checkpointUpdate {
            return .init(sessionId: session.id,
                         fileSize: update.checkpoint.sources.values.reduce(0) { $0 + $1.snapshot.size },
                         mtime: update.checkpoint.sources[session.filePath]?.snapshot.modifiedAt ?? session.lastModified,
                         stats: stats, searchIndexUpdate: update.searchIndex, checkpoint: update.checkpoint,
                         expectedCheckpoint: .matches(expectedCheckpointID), quickStats: update.quickStats)
        }
        return .init(sessionId: session.id, fileSize: session.fileSize, mtime: session.lastModified,
                     stats: stats, searchIndexUpdate: .replace(searchMessages), quickStats: quick)
    }
}

/// Only the compact, committed projections escape the parser's queue reservation.
/// FTS rows/checkpoint buffers are committed and released inside that reservation.
struct SessionParseCommitOutcome: Sendable {
    let stats: SessionStats?
    let quickStats: SessionQuickStats?
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
        cached: DatabaseService.CachedSession?,
        database: DatabaseService = .shared
    ) async -> SessionParseOutcome {
        await consumeParsed(provider: provider, session: session, quick: quick, cached: cached, database: database) { $0 }
    }

    static func parseAndCommit(
        provider: any SessionProvider, session: Session, quick: SessionQuickStats,
        cached: DatabaseService.CachedSession?, database: DatabaseService,
        scheduler: BackgroundWorkScheduler = .shared
    ) async -> SessionParseCommitOutcome {
        await consumeParsed(provider: provider, session: session, quick: quick, cached: cached, database: database, scheduler: scheduler) { outcome in
            guard !Task.isCancelled else {
                return SessionParseCommitOutcome(stats: nil, quickStats: nil, shouldRetry: false)
            }
            guard let request = outcome.saveRequest(for: session, quick: quick) else {
                return SessionParseCommitOutcome(stats: nil, quickStats: nil, shouldRetry: outcome.shouldRetry)
            }
            guard database.saveSessionsStatsAndIndexes(provider: provider.kind, requests: [request]) else {
                return SessionParseCommitOutcome(stats: nil, quickStats: nil, shouldRetry: true)
            }
            return SessionParseCommitOutcome(stats: request.stats,
                                             quickStats: outcome.checkpointUpdate?.quickStats ?? quick,
                                             shouldRetry: outcome.shouldRetry)
        }
    }

    private static func consumeParsed<Result: Sendable>(
        provider: any SessionProvider, session: Session, quick: SessionQuickStats,
        cached: DatabaseService.CachedSession?, database: DatabaseService,
        scheduler: BackgroundWorkScheduler = .shared,
        consume: @escaping @Sendable (SessionParseOutcome) -> Result
    ) async -> Result {
        do {
            return try await scheduler.run(
                estimatedBytes: min(max(1, session.fileSize), Int64.max / 4) * 4
            ) {
                if let checkpointed = provider as? any CheckpointedSessionDataProvider {
                    let previous = database.loadParseCheckpoint(provider: provider.kind, sessionId: session.id)
                    // An unchanged file is only a no-op if both projections are
                    // intact. Missing/stale FTS must rebuild from the same source
                    // snapshot rather than silently keeping an empty index.
                    let compatible = previous?.parserRevision == checkpointed.checkpointParserRevision &&
                        cached?.sessionStats != nil && database.hasCompleteIndex(provider: provider.kind, sessionId: session.id)
                        ? previous : nil
                    guard let update = try checkpointed.parseSessionUpdate(at: session.filePath, checkpoint: compatible) else {
                        guard compatible != nil, cached?.sessionStats != nil else { throw CheckpointError.invalidResult }
                        return consume(SessionParseOutcome(sessionId: session.id, committedStats: nil,
                                                   displayStats: cached?.sessionStats, searchMessages: [],
                                                   shouldRetry: false))
                    }
                    try Task.checkCancellation()
                    guard update.checkpoint.parserRevision == checkpointed.checkpointParserRevision,
                          update.checkpoint.sources[session.filePath] != nil,
                          update.checkpoint.sources.values.allSatisfy({ $0.offset >= 0 && $0.offset <= $0.snapshot.size }),
                          suspiciousReason(stats: update.stats, quick: update.quickStats, session: session) == nil else {
                        throw CheckpointError.invalidResult
                    }
                    return consume(SessionParseOutcome(sessionId: session.id, committedStats: update.stats,
                                               displayStats: update.stats, searchMessages: [], shouldRetry: false, checkpointUpdate: update,
                                               expectedCheckpointID: previous?.id))
                }
                let outcome = try await parseWithinBudget(provider: provider, session: session, quick: quick,
                                                         cached: cached)
                try Task.checkCancellation()
                return consume(outcome)
            }
        } catch {
            return consume(SessionParseOutcome(sessionId: session.id, committedStats: nil,
                                       displayStats: cached?.sessionStats, searchMessages: [],
                                       shouldRetry: !(error is CancellationError)))
        }
    }

    private enum CheckpointError: Error { case invalidResult }

    private static func parseWithinBudget(
        provider: any SessionProvider, session: Session, quick: SessionQuickStats,
        cached: DatabaseService.CachedSession?
    ) async throws -> SessionParseOutcome {
        // PR6: combined parse + FTS extract — one file IO, one decode
        // pass per pass through the validator.
        let firstResult = try parseLegacySnapshot(provider: provider, path: session.filePath)
        guard !Task.isCancelled else {
            return SessionParseOutcome(sessionId: session.id, committedStats: nil,
                                       displayStats: cached?.sessionStats, searchMessages: [],
                                       shouldRetry: false)
        }
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

        guard !Task.isCancelled else {
            return SessionParseOutcome(sessionId: session.id, committedStats: nil,
                                       displayStats: cached?.sessionStats, searchMessages: [],
                                       shouldRetry: false)
        }

        let retryResult = try parseLegacySnapshot(provider: provider, path: session.filePath)
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

    private static func parseLegacySnapshot(provider: any SessionProvider, path: String) throws -> SessionParseResult {
        try autoreleasepool {
            try Task.checkCancellation()
            let before = try TranscriptFileSnapshot.read(at: path)
            let result = provider.parseSessionAndSearchIndex(at: path)
            try Task.checkCancellation()
            // The old API cannot reconcile two different source generations.
            // Retry later instead of committing statistics and index from a
            // file that changed between its two optional parser passes.
            guard try TranscriptFileSnapshot.read(at: path) == before else {
                throw TranscriptFileReader.ReadError.changedDuringRead
            }
            return result
        }
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
