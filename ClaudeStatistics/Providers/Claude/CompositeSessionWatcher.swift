import ClaudeStatisticsKit

/// Presents several watched transcript roots as the single watcher handle the
/// provider protocol expects.
final class CompositeSessionWatcher: SessionWatcher {
    private let watchers: [any SessionWatcher]

    init(watchers: [any SessionWatcher]) {
        self.watchers = watchers
    }

    func start() {
        watchers.forEach { $0.start() }
    }

    func stop() {
        watchers.forEach { $0.stop() }
    }
}
