import Foundation
import os

/// Lightweight `OSSignposter` wrapper for the performance optimization
/// project (see docs/PERFORMANCE_OPTIMIZATION_PROJECT.md). Cost is near
/// zero when no Instruments tool is attached, so call sites can stay
/// instrumented in shipping builds.
///
/// View signposts in Instruments → Time Profiler / Logging → filter by
/// subsystem `com.tinystone.ClaudeStatistics`, category `performance`.
enum PerformanceTracer {
    static let signposter = OSSignposter(
        subsystem: "com.tinystone.ClaudeStatistics",
        category: "performance"
    )

    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    @discardableResult
    static func measureAsync<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await body()
    }

    /// Begin/end pair for spans that cross closure boundaries (e.g.
    /// inside a `Task.detached`). Pair each `begin` with exactly one
    /// `end` carrying the returned state.
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
