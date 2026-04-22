import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    /// Posted when something inside the popover wants it dismissed — e.g.
    /// the settings pane's "Open Accessibility Settings" button handing off
    /// focus to System Settings.
    static let closeStatusBarPanel = Notification.Name("ClaudeStatistics.closeStatusBarPanel")
}

/// Manages the NSStatusItem and the floating panel.
@MainActor
final class StatusBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem!
    private var panel: StatusBarPanel!
    private var eventMonitor: Any?
    private var hotKeyManager: GlobalHotKeyManager?
    private var cancellables = Set<AnyCancellable>()

    let appState: AppState
    private let onIslandShortcut: @MainActor () -> Bool

    init(appState: AppState, onIslandShortcut: @escaping @MainActor () -> Bool = { false }) {
        self.appState = appState
        self.onIslandShortcut = onIslandShortcut
        super.init()
        setupStatusItem()
        setupPanel()
        observeMenuBarText()
        setupHotKey()

        // Allow anywhere in the app (e.g. the "open system settings" button
        // in SettingsView) to request the popover panel be dismissed.
        NotificationCenter.default.addObserver(
            forName: .closeStatusBarPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                self.hidePanel()
            }
        }
    }

    private func setupHotKey() {
        hotKeyManager = GlobalHotKeyManager(actions: [
            .panel: { [weak self] in
                self?.togglePanel(nil)
            },
            .island: { [weak self] in
                guard let self else { return }
                if !self.onIslandShortcut() {
                    self.togglePanel(nil)
                }
            }
        ])
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = appState.menuBarText
            button.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(togglePanel)
        }
    }

    private func observeMenuBarText() {
        appState.usageViewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.statusItem.button?.title = self.appState.menuBarText
            }
            .store(in: &cancellables)

        appState.$providerKind
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.statusItem.button?.title = self.appState.menuBarText
            }
            .store(in: &cancellables)
    }

    // MARK: - Panel

    private func setupPanel() {
        let defaultRect = NSRect(x: 0, y: 0, width: 520, height: 620)
        panel = StatusBarPanel(contentRect: defaultRect)

        let hostingView = NSHostingView(rootView:
            PanelContentView(appState: appState)
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // Add hosting view inside the visual effect view
        if let effectView = panel.contentView {
            effectView.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: effectView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            ])
        }
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: false)
        appState.usageViewModel.loadCache()
        appState.popoverDidOpen()

        // Install event monitor after a tiny delay to avoid catching the triggering click
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.installEventMonitor()
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        appState.popoverDidClose()
        removeEventMonitor()
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func positionPanel() {
        guard let buttonFrame = statusItem.button?.window?.frame else { return }

        let panelSize = panel.frame.size
        let x = buttonFrame.midX - panelSize.width / 2
        let y = buttonFrame.minY - panelSize.height

        // Clamp to screen bounds
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let clampedX = max(screenFrame.minX, min(x, screenFrame.maxX - panelSize.width))
            let clampedY = max(screenFrame.minY, y)
            panel.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}
