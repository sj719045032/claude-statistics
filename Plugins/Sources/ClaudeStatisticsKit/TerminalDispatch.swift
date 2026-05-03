import Foundation

/// Plugin-side entry point for opening a terminal at a given working
/// directory with an initial command. The host registers a single
/// dispatcher closure at startup that funnels into its
/// `TerminalRegistry.launch(_:)` (which picks the user's preferred
/// terminal app, focus mode, etc.). Plugins call this from their
/// `SessionLauncher` implementations instead of importing the host
/// `TerminalRegistry` directly — that import isn't possible from a
/// `.csplugin` target.
///
/// Thread-safe: the host wires the dispatcher exactly once on the main
/// actor before any plugin gets a chance to invoke `launch(_:)`. Reads
/// of `_dispatcher` are protected by a lock so a plugin call from a
/// non-main thread (e.g. an `async` Task) doesn't race the install.
public enum TerminalDispatch {
    private static let lock = NSLock()
    private static var _dispatcher: (@Sendable (TerminalLaunchRequest) -> Void)?
    private static var _noticeDispatcher: (@Sendable (String) -> Void)?

    /// Wire the host-side launcher. Idempotent — calling twice replaces
    /// the previous closure (host shouldn't, but a future test harness
    /// might re-install a stub between cases).
    public static func setDispatcher(_ dispatcher: @escaping @Sendable (TerminalLaunchRequest) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        _dispatcher = dispatcher
    }

    public static func setNoticeDispatcher(_ dispatcher: @escaping @Sendable (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        _noticeDispatcher = dispatcher
    }

    /// Forward a launch request to whatever the host registered. Calls
    /// before `setDispatcher` was invoked are silently dropped — this
    /// is the same semantics as the legacy `TerminalRegistry.launch`
    /// path when no terminal capability is configured.
    public static func launch(_ request: TerminalLaunchRequest) {
        lock.lock()
        let dispatcher = _dispatcher
        lock.unlock()
        dispatcher?(request)
    }

    public static func notify(_ message: String) {
        lock.lock()
        let dispatcher = _noticeDispatcher
        lock.unlock()
        dispatcher?(message)
    }
}
