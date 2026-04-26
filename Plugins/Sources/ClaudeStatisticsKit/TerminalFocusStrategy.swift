import Foundation

/// Plugin contribution that puts focus inside a previously-captured
/// terminal location. Each `TerminalPlugin` may declare one strategy;
/// the host's focus coordinator invokes the strategy whose plugin owns
/// the target's bundle id.
///
/// Three entry points reflect the host's existing focus-pipeline
/// stages:
///
/// - `capability(for:)` — synchronous probe used by the UI to decide
///   whether to surface "set up <terminal>" prompts before the user
///   triggers focus. No side effects.
/// - `directFocus(target:)` — fast path using the recorded identity
///   (tab id / window id / surface id / socket). Returns `nil` to
///   signal the host should fall back to `resolvedFocus`.
/// - `resolvedFocus(target:)` — slow path that may activate the app,
///   walk the process tree, query Accessibility, etc. Returns the
///   freshly resolved capability + stable id so the host can replace
///   the cached identity for future invocations.
///
/// Implementations are typically structs and can be `Sendable` since
/// they hold only configuration (no per-invocation state).
public protocol TerminalFocusStrategy: Sendable {
    /// Synchronous capability probe. Used by the UI before any focus
    /// attempt to decide whether the strategy can deliver `.ready`
    /// (precise tab focus), `.appOnly` (just app activation), or needs
    /// further setup (`.requiresAccessibility`).
    func capability(for target: TerminalFocusTarget) -> TerminalFocusCapability

    /// Best-effort focus using the recorded identity in `target`.
    /// Returns `nil` when the strategy can't act on the recorded
    /// identity (missing fields, stale ids, etc.) — host then falls
    /// back to `resolvedFocus`.
    func directFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult?

    /// Recovery path that may activate the app, query Accessibility,
    /// or re-resolve identity from the process tree. Returns the
    /// (possibly updated) capability + a freshly resolved stable id
    /// so the host can replace the cached target.
    func resolvedFocus(target: TerminalFocusTarget) async -> TerminalFocusExecutionResult?
}
