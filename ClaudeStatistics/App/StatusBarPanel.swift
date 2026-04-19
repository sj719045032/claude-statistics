import AppKit
import SwiftUI

/// Custom NSPanel that looks like a menu bar popover but supports native resizing.
final class StatusBarPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.stationary, .moveToActiveSpace, .fullScreenAuxiliary]

        // Persist frame automatically
        setFrameAutosaveName("StatusBarPanel")

        minSize = NSSize(width: 480, height: 520)
        maxSize = NSSize(width: 800, height: 900)

        // Popover-style background with rounded corners
        let effectView = NSVisualEffectView()
        effectView.material = .sidebar
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 10
        effectView.layer?.masksToBounds = true
        contentView = effectView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Close on Escape key
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
