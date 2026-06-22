import Foundation
import ClaudeStatisticsKit

/// Fans `start()` / `stop()` out to several `SessionWatcher`s so a provider can
/// watch more than one root directory behind a single watcher handle. The
/// Claude provider uses it to watch both `~/.claude/projects` and the Cowork
/// (local agent mode) transcript tree.
final class CompositeSessionWatcher: SessionWatcher {
    private let watchers: [any SessionWatcher]

    init(watchers: [any SessionWatcher]) {
        self.watchers = watchers
    }

    func start() {
        for watcher in watchers { watcher.start() }
    }

    func stop() {
        for watcher in watchers { watcher.stop() }
    }
}
