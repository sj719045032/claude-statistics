import AppKit
import Combine
import Foundation

/// Live tracker for the user-configured "skip confirm" modifier combo.
/// Views observe `isPressed` to give immediate visual feedback (e.g.
/// a delete button switching to a "delete now" appearance while the
/// combo is held). Backed by a single NSEvent monitor and a shared
/// instance so all destructive buttons stay in sync without each
/// installing its own monitor.
final class SkipConfirmKeyMonitor: ObservableObject {
    static let shared = SkipConfirmKeyMonitor()

    @Published private(set) var isPressed: Bool = false

    private var localMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.recompute(flags: event.modifierFlags)
            return event
        }

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recompute(flags: NSEvent.modifierFlags)
        }

        recompute(flags: NSEvent.modifierFlags)
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func recompute(flags: NSEvent.ModifierFlags) {
        let pressed = SkipConfirmShortcut.matches(flags)
        if pressed != isPressed {
            isPressed = pressed
        }
    }
}
