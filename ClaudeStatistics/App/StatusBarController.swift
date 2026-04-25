import AppKit
import ApplicationServices
import SwiftUI
import Combine

extension Notification.Name {
    /// Posted when something inside the popover wants it dismissed — e.g.
    /// the settings pane's "Open Accessibility Settings" button handing off
    /// focus to System Settings.
    static let closeStatusBarPanel = Notification.Name("ClaudeStatistics.closeStatusBarPanel")
}

enum AccessibilityPermissionSupport {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func registerVisibility(prompt: Bool) {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: prompt] as CFDictionary)
    }

    static func registerViaEventTapProbe() {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let noopCallback: CGEventTapCallBack = { _, _, event, _ in
            Unmanaged.passUnretained(event)
        }

        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: noopCallback,
            userInfo: nil
        ) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    static func openSystemSettings(closePanel: Bool = true) {
        registerViaEventTapProbe()

        if closePanel {
            NotificationCenter.default.post(name: .closeStatusBarPanel, object: nil)
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
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
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
        // Disable the default button image/title so the hosting view renders
        // unobstructed.
        button.image = nil
        button.title = ""

        // SwiftUI measures its own size; NSStatusItem doesn't auto-track
        // subview intrinsic size, so the strip hands its measured width
        // back here and we pin `statusItem.length` to it. Minimum width
        // keeps the button clickable even before the first measurement
        // arrives.
        let strip = MenuBarUsageStrip(appState: appState) { [weak self] size in
            guard let self else { return }
            let desired = max(28, size.width.rounded(.up))
            if self.statusItem.length != desired {
                self.statusItem.length = desired
            }
        }
        let hosting = NSHostingView(rootView: strip)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(hosting)

        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: button.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
        ])

        // Seed a reasonable initial width so the strip isn't clipped on
        // first display while SwiftUI runs its first measurement pass.
        statusItem.length = hosting.fittingSize.width > 0 ? hosting.fittingSize.width : 96
    }

    private func observeMenuBarText() {
        // No longer needed — SwiftUI inside NSHostingView subscribes to
        // each UsageViewModel directly and re-renders on data changes.
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

// MARK: - Menu bar usage strip (multi-provider display)

/// Status bar button content: one compact cell per user-enabled provider
/// with icon on top and current usage text below. Subscribes to the
/// provider-specific UsageViewModel via AppState so updates propagate
/// without manual wiring.
struct MenuBarUsageStrip: View {
    @ObservedObject var appState: AppState
    @AppStorage(MenuBarPreferences.key(for: .claude)) private var claudeVisible = true
    @AppStorage(MenuBarPreferences.key(for: .codex)) private var codexVisible = true
    @AppStorage(MenuBarPreferences.key(for: .gemini)) private var geminiVisible = true
    var onSizeChange: (CGSize) -> Void = { _ in }

    /// Shared rotation counter — lives on the strip (not inside each cell)
    /// so every cell advances to the next segment at exactly the same
    /// moment. One timer, one tick, no drift between cells.
    @State private var tick: Int = 0
    private static let rotationInterval: TimeInterval = 3

    var body: some View {
        HStack(spacing: 4) {
            ForEach(visibleKinds, id: \.self) { kind in
                if let vm = appState.usageViewModel(for: kind) {
                    MenuBarUsageCell(kind: kind, viewModel: vm, tick: tick)
                }
            }
        }
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: MenuBarStripSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(MenuBarStripSizeKey.self, perform: onSizeChange)
        .onReceive(Timer.publish(every: Self.rotationInterval, on: .main, in: .common).autoconnect()) { _ in
            tick &+= 1
        }
    }

    private var visibleKinds: [ProviderKind] {
        var kinds: [ProviderKind] = []
        if claudeVisible { kinds.append(.claude) }
        if codexVisible { kinds.append(.codex) }
        if geminiVisible { kinds.append(.gemini) }
        return kinds
    }
}

private struct MenuBarStripSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct MenuBarUsageCell: View {
    let kind: ProviderKind
    @ObservedObject var viewModel: UsageViewModel
    /// Shared rotation counter driven by the parent `MenuBarUsageStrip` so
    /// all cells advance in lockstep.
    let tick: Int

    /// Fixed cell width. Tight-fit around icon(15) + inner spacing(5) +
    /// text (~20pt for "100%") = 40pt, snapped to 42 so the cell doesn't
    /// breathe as segment values change.
    private static let cellWidth: CGFloat = 42

    var body: some View {
        HStack(spacing: 5) {
            Image(kind.statusIconAssetName)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 15, height: 15)
                .foregroundStyle(.primary)
            VStack(alignment: .center, spacing: -1) {
                Text(currentSegment?.prefix ?? "—")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                Text(currentSegment?.value ?? " ")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(color(for: currentSegment))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(width: Self.cellWidth, alignment: .leading)
        .help(kind.displayName)
    }

    private var segments: [MenuBarStripSegment] {
        ProviderRegistry.provider(for: kind).menuBarStripSegments(from: viewModel.usageData)
    }

    private var currentSegment: MenuBarStripSegment? {
        let segs = segments
        guard !segs.isEmpty else { return nil }
        return segs[abs(tick) % segs.count]
    }

    private func color(for segment: MenuBarStripSegment?) -> Color {
        guard let segment else { return .secondary }
        if segment.usedPercent >= 80 { return .red }
        if segment.usedPercent >= 50 { return .orange }
        return .primary
    }
}
