import Foundation

/// Lifecycle handle for a per-provider file-system watcher. The host
/// holds one of these per active `SessionDataProvider` and calls
/// `start` / `stop` around presentation visibility (panel open/close)
/// and provider-switch transitions. Plugins typically return an
/// `FSEventsWatcher` instance from their `makeWatcher(onChange:)`
/// factory, but any object that implements this protocol works —
/// e.g. a SQLite-listener plugin can return its own change source.
public protocol SessionWatcher: AnyObject {
    func start()
    func stop()
}
