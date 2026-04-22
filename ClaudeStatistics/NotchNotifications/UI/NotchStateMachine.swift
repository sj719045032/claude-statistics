import Foundation
import Combine
import SwiftUI

enum NotchDisplayState: Equatable {
    case idle
    case compact
    case expanded
}

@MainActor
final class NotchStateMachine: ObservableObject {
    @Published private(set) var state: NotchDisplayState = .idle
    /// True when the current `.expanded` state was entered by hover upgrading
    /// from `.compact` — not by an event. Hover-initiated expansions should
    /// collapse back immediately when the mouse leaves; event-initiated ones
    /// stay until the user dismisses or the event times out.
    private(set) var expandedViaHover = false

    // Compact (closed) — matches physical notch dimensions on notch Macs
    static let compactWidth: CGFloat  = 200
    static let compactHeight: CGFloat = 32
    static let closedTopCornerRadius: CGFloat    = 6
    static let closedBottomCornerRadius: CGFloat = 14

    // Expanded (opened) — Dynamic Island style
    static let expandedWidth: CGFloat     = 440
    static let expandedMinHeight: CGFloat = 150
    static let openedTopCornerRadius: CGFloat    = 19
    static let openedBottomCornerRadius: CGFloat = 24

    // Window frame sized to hold the largest expected card + breathing room
    static let windowWidth: CGFloat  = 640
    static let windowHeight: CGFloat = 360

    // Animation presets borrowed from Dynamic Island conventions
    static let openAnimation  = SwiftUI.Animation.spring(response: 0.42, dampingFraction: 0.80)
    static let closeAnimation = SwiftUI.Animation.spring(response: 0.45, dampingFraction: 1.00)
    static let hoverAnimation = SwiftUI.Animation.spring(response: 0.38, dampingFraction: 0.80)

    private var idleTimer: DispatchSourceTimer?

    func show(expanded: Bool = false) {
        cancelIdleTimer()
        expandedViaHover = false
        state = expanded ? .expanded : .compact
        if !expanded { scheduleIdleTimer() }
    }

    func expand() {
        cancelIdleTimer()
        expandedViaHover = false
        state = .expanded
    }

    func collapse() {
        expandedViaHover = false
        state = .compact
        scheduleIdleTimer()
    }

    func hide() {
        cancelIdleTimer()
        expandedViaHover = false
        state = .idle
    }

    /// Transition directly into a hover-driven peek without going through
    /// `.compact` + scheduled idle timer. Called when an event card closes
    /// while the user is still hovering and was already peeking before the
    /// event arrived — so the list card "comes back" after the event card
    /// dismisses, without a visible hide/reshow bounce.
    func restoreHoverPeek() {
        cancelIdleTimer()
        state = .expanded
        expandedViaHover = true
    }

    func handleHover(_ hovering: Bool) {
        if hovering {
            cancelIdleTimer()
            if state == .compact {
                state = .expanded
                expandedViaHover = true
            }
        } else if state == .expanded, expandedViaHover {
            // Hover-initiated peek — collapse back immediately on mouse-leave.
            expandedViaHover = false
            state = .compact
            scheduleIdleTimer()
        }
        // Event-initiated expansions stay until explicit dismissal.
    }

    private func scheduleIdleTimer() {
        cancelIdleTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 7)
        timer.setEventHandler { [weak self] in self?.idleTimerFired() }
        timer.resume()
        idleTimer = timer
    }

    private func idleTimerFired() {
        idleTimer = nil
        if state == .expanded { state = .compact }
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }
}
