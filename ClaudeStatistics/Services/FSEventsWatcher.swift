import Foundation
import CoreServices

final class FSEventsWatcher {
    private let path: String
    private let debounceSeconds: TimeInterval
    private let fileFilter: (String) -> Bool
    private let onChange: (Set<String>) -> Void

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.claude-statistics.fswatcher", qos: .utility)
    private var pendingPaths: Set<String> = []
    private var debounceWork: DispatchWorkItem?

    init(
        path: String,
        debounceSeconds: TimeInterval = 2.0,
        fileFilter: @escaping (String) -> Bool = { $0.hasSuffix(".jsonl") },
        onChange: @escaping (Set<String>) -> Void
    ) {
        self.path = path
        self.debounceSeconds = debounceSeconds
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
        guard let eventStream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceSeconds * 0.5, // Low latency; we do our own debounce
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        stream = eventStream
        FSEventStreamSetDispatchQueue(eventStream, queue)
        FSEventStreamStart(eventStream)
    }

    func stop() {
        debounceWork?.cancel()
        debounceWork = nil
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

    fileprivate func handleEvents(_ paths: [String]) {
        let matchingPaths = paths.filter(fileFilter)
        guard !matchingPaths.isEmpty else { return }

        pendingPaths.formUnion(matchingPaths)

        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let collected = self.pendingPaths
            self.pendingPaths.removeAll()
            guard !collected.isEmpty else { return }
            DispatchQueue.main.async {
                self.onChange(collected)
            }
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
    }
}

extension FSEventsWatcher: SessionWatcher {}

// C callback — extracts file paths and forwards to instance
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
    watcher.handleEvents(cfPaths)
}
