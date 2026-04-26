import Foundation
import CoreServices

final class FSEventsWatcher {
    /// Differentiated debounce: single-file appends are surfaced quickly so
    /// the UI feels responsive after a CLI writes a new chunk; structural
    /// changes (creates / removes / renames / directory events) are
    /// debounced longer to coalesce bursts like `git checkout` switching a
    /// large folder of session logs.
    struct DebounceConfig {
        let fast: TimeInterval   // single-file append path
        let slow: TimeInterval   // structural / directory path
        static let `default` = DebounceConfig(fast: 0.2, slow: 2.0)
        /// Drop-in replacement for the legacy single-value debounce so
        /// existing call sites that pass a number still get a sensible
        /// configuration without behaviour drift.
        static func legacy(_ value: TimeInterval) -> DebounceConfig {
            DebounceConfig(fast: max(0.2, value * 0.1), slow: value)
        }
    }

    private let path: String
    private let debounce: DebounceConfig
    private let fileFilter: (String) -> Bool
    private let onChange: (Set<String>) -> Void

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.claude-statistics.fswatcher", qos: .utility)
    private var fastPending: Set<String> = []
    private var slowPending: Set<String> = []
    private var fastWork: DispatchWorkItem?
    private var slowWork: DispatchWorkItem?

    init(
        path: String,
        debounceSeconds: TimeInterval = 2.0,
        fileFilter: @escaping (String) -> Bool = { $0.hasSuffix(".jsonl") },
        onChange: @escaping (Set<String>) -> Void
    ) {
        self.path = path
        self.debounce = .legacy(debounceSeconds)
        self.fileFilter = fileFilter
        self.onChange = onChange
    }

    init(
        path: String,
        debounce: DebounceConfig,
        fileFilter: @escaping (String) -> Bool = { $0.hasSuffix(".jsonl") },
        onChange: @escaping (Set<String>) -> Void
    ) {
        self.path = path
        self.debounce = debounce
        self.fileFilter = fileFilter
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: selfPtr,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [path] as CFArray
        // FSEvents native latency stays low; differentiation happens in
        // the Swift-side per-flag debounce below.
        let nativeLatency: TimeInterval = max(0.1, debounce.fast * 0.5)
        guard let eventStream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            nativeLatency,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        stream = eventStream
        FSEventStreamSetDispatchQueue(eventStream, queue)
        FSEventStreamStart(eventStream)
    }

    func stop() {
        fastWork?.cancel()
        slowWork?.cancel()
        fastWork = nil
        slowWork = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit {
        stop()
    }

    // MARK: - Internal

    fileprivate func handleEvents(_ events: [(path: String, flags: FSEventStreamEventFlags)]) {
        var fastBatch: Set<String> = []
        var slowBatch: Set<String> = []
        for event in events where fileFilter(event.path) {
            if Self.isStructural(event.flags) {
                slowBatch.insert(event.path)
            } else {
                fastBatch.insert(event.path)
            }
        }
        if !fastBatch.isEmpty { schedule(fast: fastBatch) }
        if !slowBatch.isEmpty { schedule(slow: slowBatch) }
    }

    private static func isStructural(_ flags: FSEventStreamEventFlags) -> Bool {
        let structural: UInt32 =
            UInt32(kFSEventStreamEventFlagItemCreated)
            | UInt32(kFSEventStreamEventFlagItemRemoved)
            | UInt32(kFSEventStreamEventFlagItemRenamed)
            | UInt32(kFSEventStreamEventFlagItemIsDir)
            | UInt32(kFSEventStreamEventFlagMustScanSubDirs)
            | UInt32(kFSEventStreamEventFlagRootChanged)
        return (flags & structural) != 0
    }

    private func schedule(fast batch: Set<String>) {
        fastPending.formUnion(batch)
        fastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let collected = self.fastPending
            self.fastPending.removeAll()
            guard !collected.isEmpty else { return }
            DispatchQueue.main.async { self.onChange(collected) }
        }
        fastWork = work
        queue.asyncAfter(deadline: .now() + debounce.fast, execute: work)
    }

    private func schedule(slow batch: Set<String>) {
        slowPending.formUnion(batch)
        slowWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let collected = self.slowPending
            self.slowPending.removeAll()
            guard !collected.isEmpty else { return }
            DispatchQueue.main.async { self.onChange(collected) }
        }
        slowWork = work
        queue.asyncAfter(deadline: .now() + debounce.slow, execute: work)
    }
}

extension FSEventsWatcher: SessionWatcher {}

// C callback — extracts file paths + flags and forwards to instance
private func fsEventsCallback(
    _ streamRef: ConstFSEventStreamRef,
    _ clientCallBackInfo: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()

    guard let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
    var collected: [(path: String, flags: FSEventStreamEventFlags)] = []
    collected.reserveCapacity(cfPaths.count)
    for index in 0..<min(numEvents, cfPaths.count) {
        collected.append((cfPaths[index], eventFlags[index]))
    }
    watcher.handleEvents(collected)
}
