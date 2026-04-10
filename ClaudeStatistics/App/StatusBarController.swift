import AppKit
import SwiftUI
import Combine

/// Manages the NSStatusItem and the floating panel.
@MainActor
final class StatusBarController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem!
    private var panel: StatusBarPanel!
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init()
        setupStatusItem()
        setupPanel()
        observeMenuBarText()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.target = self
            button.action = #selector(togglePanel)
        }
        refreshStatusItemLabel()
    }

    private func observeMenuBarText() {
        let usagePublishers: [AnyPublisher<Void, Never>] = [
            appState.usageViewModel.objectWillChange.eraseToAnyPublisher(),
            appState.zaiUsageViewModel.objectWillChange.eraseToAnyPublisher(),
            appState.openAIUsageViewModel.objectWillChange.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(usagePublishers)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusItemLabel()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusItemLabel()
            }
            .store(in: &cancellables)
    }

    private func refreshStatusItemLabel() {
        guard let button = statusItem.button else { return }

        switch MenuBarUsageSelection.displayMode(for: menuBarItems) {
        case .logo:
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
        case let .usage(items):
            let image = statusImage(for: items)
            button.image = image
            button.image?.isTemplate = false
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    private var menuBarItems: [MenuBarUsageItem] {
        MenuBarUsageSelection.items(
            claudeFiveHourPercent: appState.usageViewModel.menuBarFiveHourPercent,
            zaiFiveHourPercent: appState.zaiUsageViewModel.fiveHourPercent,
            openAIFiveHourPercent: appState.openAIUsageViewModel.currentWindowPercent,
            zaiEnabled: UserDefaults.standard.bool(forKey: "zaiUsageEnabled"),
            openAIEnabled: UserDefaults.standard.bool(forKey: "openAIUsageEnabled")
        )
    }

    private func statusImage(for items: [MenuBarUsageItem]) -> NSImage {
        let attributedString = NSMutableAttributedString()

        for fragment in MenuBarUsageSelection.styledFragments(from: items) {
            attributedString.append(
                NSAttributedString(
                    string: fragment.text,
                    attributes: attributes(for: fragment.style)
                )
            )
        }

        let measuredSize = attributedString.size()
        let imageSize = NSSize(
            width: ceil(measuredSize.width),
            height: max(14, ceil(measuredSize.height))
        )
        let image = NSImage(size: imageSize)
        image.lockFocus()
        attributedString.draw(
            at: NSPoint(
                x: 0,
                y: floor((imageSize.height - measuredSize.height) / 2)
            )
        )
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func attributes(for style: MenuBarUsageTextStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case .providerLabel:
            return [
                .font: NSFont.systemFont(ofSize: MenuBarUsageSelection.compactProviderFontSize, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        case .separator:
            return [
                .font: NSFont.systemFont(ofSize: MenuBarUsageSelection.compactProviderFontSize, weight: .regular),
                .foregroundColor: NSColor.white
            ]
        case let .percentage(role):
            return [
                .font: NSFont.monospacedDigitSystemFont(ofSize: MenuBarUsageSelection.compactPercentFontSize, weight: .bold),
                .foregroundColor: color(for: role)
            ]
        }
    }

    private func color(for role: MenuBarUsageColorRole) -> NSColor {
        switch role {
        case .green:
            return .systemGreen
        case .yellow:
            return .systemYellow
        case .critical:
            return .systemRed
        }
    }

    // MARK: - Panel

    private func setupPanel() {
        let defaultRect = NSRect(x: 0, y: 0, width: 520, height: 620)
        panel = StatusBarPanel(contentRect: defaultRect)

        let hostingView = NSHostingView(rootView:
            PanelContentView(
                usageViewModel: appState.usageViewModel,
                profileViewModel: appState.profileViewModel,
                sessionViewModel: appState.sessionViewModel,
                store: appState.store,
                updaterService: appState.updaterService,
                notificationService: appState.notificationService,
                zaiUsageViewModel: appState.zaiUsageViewModel,
                openAIUsageViewModel: appState.openAIUsageViewModel
            )
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
        appState.store.popoverDidOpen()

        // Install event monitor after a tiny delay to avoid catching the triggering click
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.installEventMonitor()
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        appState.store.popoverDidClose()
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
