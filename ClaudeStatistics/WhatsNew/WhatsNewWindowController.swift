import AppKit
import SwiftUI

/// Hosts `WhatsNewView` inside a borderless utility panel. We use
/// `NSWindowController` (not the Settings scene) because the app is
/// `LSUIElement` — there's no main window, so SwiftUI scenes can't
/// give us a free-standing presentation slot.
@MainActor
final class WhatsNewWindowController: NSWindowController {
    private static var shared: WhatsNewWindowController?

    /// Show (or re-focus) the panel for `release`. Re-uses the
    /// singleton so spamming the menu item doesn't stack windows.
    static func present(release: WhatsNewRelease) {
        if let existing = shared {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = WhatsNewWindowController(release: release)
        shared = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(release: WhatsNewRelease) {
        let hosting = NSHostingController(
            rootView: WhatsNewView(release: release, dismiss: { Self.dismiss() })
        )
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.title = NSLocalizedString("whatsnew.window.title", comment: "")
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("WhatsNewWindowController does not support coder init")
    }

    static func dismiss() {
        shared?.close()
    }
}

extension WhatsNewWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        WhatsNewWindowController.shared = nil
    }
}
