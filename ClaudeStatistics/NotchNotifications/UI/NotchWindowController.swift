import AppKit
import ApplicationServices
import Carbon
import SwiftUI

@MainActor
final class NotchHoverState: ObservableObject {
    @Published private(set) var islandHovering = false

    func setIslandHovering(_ hovering: Bool) {
        guard islandHovering != hovering else { return }
        islandHovering = hovering
    }
}

enum NotchKeyboardAction {
    case left
    case right
    case up
    case down
    case confirm
    case cancel
}

@MainActor
final class NotchKeyboardState: ObservableObject {
    @Published private(set) var generation = 0
    private(set) var action: NotchKeyboardAction?

    func send(_ action: NotchKeyboardAction) {
        self.action = action
        generation &+= 1
    }
}

enum NotchIslandCommand {
    case toggleIdlePeekFromShortcut
}

@MainActor
final class NotchIslandCommandState: ObservableObject {
    @Published private(set) var generation = 0
    private(set) var command: NotchIslandCommand?

    func send(_ command: NotchIslandCommand) {
        self.command = command
        generation &+= 1
    }
}

@MainActor
final class NotchWindowController {
    private let window: NotchWindow
    private var hostingView: NotchHostingView<NotchContainerView>!
    let notchCenter: NotchNotificationCenter
    let machine: NotchStateMachine
    private let hoverState = NotchHoverState()
    private let keyboardState = NotchKeyboardState()
    private let islandCommandState = NotchIslandCommandState()
    private let keyboardInterceptor = NotchKeyboardInterceptor()
    private let localKeyboardMonitor = NotchLocalKeyboardMonitor()
    private let screenTracker = NotchScreenTracker()
    private var targetScreen: NSScreen?
    private var screenObservers: [NSObjectProtocol] = []
    private var lastRequestedSize: CGSize = .zero
    private var pendingResize: DispatchWorkItem?
    private var pendingResizeRequest: ResizeRequest?
    private var pendingShrink: DispatchWorkItem?
    private var resizeGeneration = 0
    private let resizeCoalesceDelay: TimeInterval = 0.01
    private let shrinkDelay: TimeInterval = 0.32
    private let finalCollapseShrinkDelay: TimeInterval = 0.12
    /// Frontmost app at the moment we started capturing keyboard for the
    /// notch card. Re-activated on release so focus returns to the user's
    /// original app (terminal/editor) instead of stranding on the panel.
    private var focusRestoreApp: NSRunningApplication?

    private struct ResizeRequest {
        let size: CGSize
        let display: Bool
        let deferShrink: Bool
    }

    init(notchCenter: NotchNotificationCenter, activeTracker: ActiveSessionsTracker) {
        self.notchCenter = notchCenter
        self.machine = NotchStateMachine()
        self.window = NotchWindow()
        self.targetScreen = notchTargetScreen()

        let rootView = NotchContainerView(notchCenter: notchCenter, machine: machine, activeTracker: activeTracker, hoverState: hoverState, keyboardState: keyboardState, islandCommandState: islandCommandState, screenTracker: screenTracker, onKeyboardCaptureChange: { [weak self] active in
            self?.setKeyboardCapture(active)
        }) { [weak self] size in
            self?.resizeWindow(to: size)
        }
        hostingView = NotchHostingView(rootView: rootView)
        hostingView.onHoverChange = { [weak hoverState] hovering in
            hoverState?.setIslandHovering(hovering)
        }
        hostingView.onKeyboardAction = { [weak keyboardState] action in
            keyboardState?.send(action)
            return true
        }
        keyboardInterceptor.onKeyboardAction = { [weak keyboardState] action in
            keyboardState?.send(action)
            return true
        }
        localKeyboardMonitor.onKeyboardAction = { [weak keyboardState] action in
            keyboardState?.send(action)
            return true
        }
        if #available(macOS 13.0, *) {
            // We drive the panel frame manually from SwiftUI measurements.
            // Disable NSHostingView's automatic window sizing bridge so it
            // doesn't fight our `setFrame` calls during constraint updates.
            hostingView.sizingOptions = []
        }

        window.contentView = hostingView
        let initialSize = initialHitSize()
        lastRequestedSize = initialSize
        resizeWindow(to: initialSize, display: false)

        updateHitRect(for: initialSize)
        window.orderFrontRegardless()
        window.makeFirstResponder(hostingView)
        startScreenTracking()
    }

    func close() {
        screenObservers.forEach { NotificationCenter.default.removeObserver($0) }
        screenObservers.removeAll()
        keyboardInterceptor.close()
        localKeyboardMonitor.close()
        pendingResize?.cancel()
        pendingResize = nil
        pendingResizeRequest = nil
        pendingShrink?.cancel()
        pendingShrink = nil
        window.orderOut(nil)
        window.close()
    }

    func toggleIdlePeekFromShortcut() {
        islandCommandState.send(.toggleIdlePeekFromShortcut)
    }

    private func resizeWindow(to size: CGSize, display: Bool = true, deferShrink: Bool = true) {
        pendingResizeRequest = ResizeRequest(size: size, display: display, deferShrink: deferShrink)
        lastRequestedSize = size
        resizeGeneration += 1

        pendingResize?.cancel()
        let generation = resizeGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.resizeGeneration, let request = self.pendingResizeRequest else { return }
            self.pendingResize = nil
            self.pendingResizeRequest = nil
            self.applyResizeWindow(to: request.size, display: request.display, deferShrink: request.deferShrink, generation: generation)
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeCoalesceDelay, execute: work)
    }

    private func applyResizeWindow(to size: CGSize, display: Bool = true, deferShrink: Bool = true, generation: Int? = nil) {
        lastRequestedSize = size
        guard let screen = targetScreen ?? notchTargetScreen() else { return }
        let w = ceil(max(1, size.width))
        let h = ceil(max(1, size.height))
        let cx = screen.frame.midX
        let top = screen.frame.maxY
        let frame = CGRect(x: cx - w / 2, y: top - h, width: w, height: h)

        let isShrinking = frame.width < window.frame.width || frame.height < window.frame.height
        if isShrinking && display && deferShrink {
            DiagnosticLogger.shared.verbose(
                "Island window defer shrink from=\(Int(self.window.frame.width))x\(Int(self.window.frame.height)) to=\(Int(frame.width))x\(Int(frame.height)) delay=\(String(format: "%.2f", self.deferredShrinkDelay(to: frame)))"
            )
            scheduleDeferredShrink(to: frame, delay: deferredShrinkDelay(to: frame), generation: generation ?? resizeGeneration)
            return
        }

        resizeGeneration += generation == nil ? 1 : 0
        pendingShrink?.cancel()
        pendingShrink = nil
        if window.frame.integral != frame.integral {
            DiagnosticLogger.shared.verbose(
                "Island window set frame to=\(Int(frame.width))x\(Int(frame.height)) shrinking=\(isShrinking) display=\(display)"
            )
            window.setFrame(frame, display: display, animate: false)
        }
        updateHitRect(for: size)
    }

    private func startScreenTracking() {
        let selectionObserver = NotificationCenter.default.addObserver(
            forName: NotchPreferences.screenChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTargetScreenFromPreference()
            }
        }
        screenObservers.append(selectionObserver)

        let displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTargetScreenFromPreference()
            }
        }
        screenObservers.append(displayObserver)
    }

    private func refreshTargetScreenFromPreference() {
        guard let nextScreen = notchTargetScreen() else { return }

        let previousInitial = initialHitSize(for: targetScreen)
        let wasIdleSized = lastRequestedSize.width <= previousInitial.width + 1
            && lastRequestedSize.height <= previousInitial.height + 1

        guard !isSameScreen(nextScreen, targetScreen) || wasIdleSized else { return }

        targetScreen = nextScreen
        pendingShrink?.cancel()
        pendingShrink = nil
        screenTracker.invalidate()

        let nextSize = wasIdleSized ? initialHitSize(for: nextScreen) : lastRequestedSize
        DiagnosticLogger.shared.info(
            "Island target screen preference changed frame=\(nextScreen.frame.debugDescription) notch=\(screenHasNotch(nextScreen)) size=\(Int(nextSize.width))x\(Int(nextSize.height)) selection=\(NotchPreferences.screenSelection)"
        )
        applyResizeWindow(to: nextSize, display: true, deferShrink: false)
    }

    private func isSameScreen(_ lhs: NSScreen?, _ rhs: NSScreen?) -> Bool {
        guard let lhs, let rhs else { return false }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let lhsID = lhs.deviceDescription[key] as? NSNumber
        let rhsID = rhs.deviceDescription[key] as? NSNumber
        if let lhsID, let rhsID {
            return lhsID == rhsID
        }
        return lhs.frame == rhs.frame
    }

    private func deferredShrinkDelay(to frame: CGRect) -> TimeInterval {
        let idle = initialHitSize()
        // Final collapse should keep a hint of the closing motion, but not
        // linger long enough for the content to collapse inside a still-tall
        // transparent panel.
        if frame.height <= ceil(idle.height) + 1 {
            return finalCollapseShrinkDelay
        }
        return shrinkDelay
    }

    private func scheduleDeferredShrink(to frame: CGRect, delay: TimeInterval, generation: Int) {
        pendingShrink?.cancel()

        // Constrain the hosting view's hit region to the target island size
        // immediately. The window itself stays at its current (larger) frame so
        // SwiftUI can finish its collapse animation inside a stable canvas;
        // `hitRect` prevents the transparent leftover area from eating hover or
        // clicks, so there's no need to toggle `ignoresMouseEvents`.
        updateHitRect(for: frame.size)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.resizeGeneration else { return }
            if self.window.frame.integral != frame.integral {
                DiagnosticLogger.shared.verbose(
                    "Island window apply deferred shrink to=\(Int(frame.width))x\(Int(frame.height))"
                )
                self.window.setFrame(frame, display: true, animate: false)
            }
            self.updateHitRect(for: frame.size)
            self.pendingShrink = nil
        }
        pendingShrink = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateHitRect(for size: CGSize) {
        guard let hostingView else { return }
        let bounds = hostingView.bounds
        let width = min(bounds.width, ceil(max(1, size.width)))
        let height = min(bounds.height, ceil(max(1, size.height)))
        hostingView.hitRect = CGRect(
            x: (bounds.width - width) / 2,
            y: hostingView.isFlipped ? 0 : bounds.height - height,
            width: width,
            height: height
        )
        hostingView.refreshHoverState()
    }

    private func initialHitSize(for screen: NSScreen? = nil) -> CGSize {
        let target = screen ?? targetScreen ?? notchTargetScreen()
        if screenHasNotch(target) {
            let notch = physicalNotchSize(on: target)
            return CGSize(width: notch.width + 20, height: notch.height)
        }
        return CGSize(width: 96, height: 18)
    }

    private func setKeyboardCapture(_ active: Bool) {
        // Keyboard routing relies exclusively on the global CGEventTap, which
        // requires Accessibility permission. We NEVER make the panel key —
        // doing that would yank focus away from the user's terminal/editor,
        // and there's no reliable way to hand it back for a non-activating
        // panel. If the tap can't be created (no permission), keyboard
        // shortcuts simply don't work until the user grants access via the
        // button in Settings. Mouse interaction is unaffected.
        keyboardInterceptor.setEnabled(active)
        localKeyboardMonitor.setEnabled(false)
        if active {
            window.orderFrontRegardless()
        }
    }
}

private final class NotchLocalKeyboardMonitor {
    var onKeyboardAction: ((NotchKeyboardAction) -> Bool)?

    private var monitor: Any?
    private var enabled = false

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        ensureMonitorIfNeeded()
    }

    func close() {
        enabled = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func ensureMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.enabled,
                  let action = self.map(event),
                  self.onKeyboardAction?(action) == true else {
                return event
            }
            return nil
        }
    }

    private func map(_ event: NSEvent) -> NotchKeyboardAction? {
        let disallowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(disallowed).isEmpty else {
            return nil
        }

        switch Int(event.keyCode) {
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_Return: return .confirm
        case kVK_Escape: return .cancel
        default: return nil
        }
    }
}

private final class NotchKeyboardInterceptor {
    var onKeyboardAction: ((NotchKeyboardAction) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var enabled = false
    private var warnedTapCreationFailure = false
    /// True once a CGEventTap was successfully created — the caller can rely
    /// on global interception and avoid making the panel key (which would
    /// steal focus from the user's terminal / editor).
    var hasEventTap: Bool { eventTap != nil }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        ensureTapIfNeeded()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: enabled)
        }
    }

    func close() {
        enabled = false
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func ensureTapIfNeeded() {
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard type == .keyDown,
                  let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let interceptor = Unmanaged<NotchKeyboardInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
            guard interceptor.enabled,
                  let action = interceptor.map(event: event),
                  interceptor.onKeyboardAction?(action) == true else {
                return Unmanaged.passUnretained(event)
            }

            return nil
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !warnedTapCreationFailure {
                DiagnosticLogger.shared.warning("Notch keyboard interceptor failed to create event tap; falling back to local key monitor")
                warnedTapCreationFailure = true
            }
            // Don't prompt here — `ClaudeStatisticsApp.registerForAccessibilityVisibility`
            // already drove the system dialog at launch. Re-prompting from the
            // tap-failure path would surface a second dialog every cold start
            // until the user grants access. The local-monitor fallback keeps
            // the notch usable in the meantime; the Settings pane has a
            // "Open Accessibility settings" button for the manual grant flow.
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: enabled)

        eventTap = tap
        runLoopSource = source
    }

    private func map(event: CGEvent) -> NotchKeyboardAction? {
        let flags = event.flags
        let disallowed: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        if !flags.intersection(disallowed).isEmpty {
            return nil
        }

        switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_Return: return .confirm
        case kVK_Escape: return .cancel
        default: return nil
        }
    }
}

// Safety net for the short-lived collapse canvas.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var hitRect: CGRect = .zero {
        didSet {
            guard oldValue.integral != hitRect.integral else { return }
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
    }
    var onHoverChange: ((Bool) -> Void)?
    var onKeyboardAction: ((NotchKeyboardAction) -> Bool)?

    private var hoverTrackingArea: NSTrackingArea?
    private var lastHovering = false

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if hitRect.contains(point) {
            return super.hitTest(point)
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }

        guard hitRect.width > 0, hitRect.height > 0 else { return }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeAlways
        ]
        let area = NSTrackingArea(rect: hitRect, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard hitRect.width > 0, hitRect.height > 0 else { return }
        addCursorRect(hitRect, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        publishHover(for: event)
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
        publishHover(for: event)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        publishHover(for: event)
        super.mouseExited(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hitRect.contains(point) {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    func refreshHoverState() {
        guard let window else {
            publishHover(false)
            return
        }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(pointInWindow, from: nil)
        publishHover(hitRect.contains(point))
    }

    private func publishHover(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        publishHover(hitRect.contains(point))
    }

    private func publishHover(_ hovering: Bool) {
        guard hovering != lastHovering else { return }
        lastHovering = hovering
        onHoverChange?(hovering)
    }

    override func keyDown(with event: NSEvent) {
        if handleKeyboard(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleKeyboard(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleKeyboard(_ event: NSEvent) -> Bool {
        let disallowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(disallowed).isEmpty,
              let action = mapKeyboardAction(event) else {
            return false
        }
        return onKeyboardAction?(action) ?? false
    }

    private func mapKeyboardAction(_ event: NSEvent) -> NotchKeyboardAction? {
        switch Int(event.keyCode) {
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_Return: return .confirm
        case kVK_Escape: return .cancel
        default: return nil
        }
    }
}
