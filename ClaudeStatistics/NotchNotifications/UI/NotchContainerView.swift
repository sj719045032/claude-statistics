import SwiftUI


// MARK: - IdlePeekLayout / TopRevealMaskShape moved to dedicated files

struct NotchContainerView: View {
    @ObservedObject var notchCenter: NotchNotificationCenter
    @ObservedObject var machine: NotchStateMachine
    @ObservedObject var activeTracker: ActiveSessionsTracker
    @ObservedObject var hoverState: NotchHoverState
    @ObservedObject var keyboardState: NotchKeyboardState
    @ObservedObject var islandCommandState: NotchIslandCommandState
    @ObservedObject var screenTracker: NotchScreenTracker
    var onKeyboardCaptureChange: (Bool) -> Void = { _ in }
    var onInteractiveSizeChange: (CGSize) -> Void = { _ in }

    // Binds to the same UserDefaults key as ActiveSessionRow's @AppStorage.
    // Declared here (even though it's not read directly in most branches) so
    // SwiftUI knows the container's body + size computations depend on it;
    // without this binding, flipping the toggle would leave the outer notch
    // window clamped to the compact-mode height.
    @AppStorage(NotchPreferences.idlePeekDetailedRowsKey)
    private var idlePeekDetailedRows: Bool = false

    // Hover state split between two zones so either keeps the island revealed.
    @State private var hoveringNotchZone = false
    @State private var hoveringIsland    = false
    @State private var pendingOpenWork: DispatchWorkItem?
    @State private var pendingIdlePeekOpen: DispatchWorkItem?
    @State private var hoverReentrySuppressed = false
    @State private var pendingHoverReentryReset: DispatchWorkItem?
    // `effectiveHovering` is what the state machine and presentation actually
    // react to. Entry is immediate; exit is deferred by `hoverLeaveDebounce`
    // so brief gaps — cross-zone rollovers, shrink relayouts, first-pass
    // Markdown measurement passes — don't flicker the island closed.
    @State private var effectiveHovering = false
    @State private var pendingHoverLeave: DispatchWorkItem?
    private let hoverLeaveDebounce: TimeInterval = 0.12
    /// When the card's measured height last changed. While this is recent the
    /// card is mid-animation (toggle, session churn, Markdown relayout), and
    /// the SwiftUI frame may briefly slide out from under the cursor — so we
    /// hold the hover leave off until the measurement has settled.
    @State private var lastCardHeightChangeAt: Date?
    private let cardMeasurementSettleWindow: TimeInterval = 0.18
    /// Internal card controls can change the island height under the cursor.
    /// For example, tapping "Show less" removes rows below the pointer, so
    /// SwiftUI reports hover=false even though the user just interacted with
    /// the card. Keep the peek alive while the mouse is still inside the
    /// pre-resize island rect, then close normally once it truly leaves.
    @State private var internalInteractionHoverGuardSize: CGSize?
    @State private var pendingInternalHoverGuardCheck: DispatchWorkItem?
    @State private var pendingNearbyHoverGuardCheck: DispatchWorkItem?
    /// Whether the user was already in an IdlePeek (hover-driven expansion)
    /// at the moment the current event card appeared. Controls what happens
    /// when the event closes:
    ///   • `true`  — user was peeking before; restore the peek, don't suppress.
    ///   • `false` — event arrived from nowhere; after close, suppress so the
    ///                list card doesn't pop up uninvited even if the mouse is
    ///                still near the notch.
    @State private var wasPeekingOnEventArrival = false
    /// Intrinsic height of the currently shown expanded card, reported up via
    /// `NotchCardIntrinsicHeightKey`. 0 until the first render measurement.
    @State private var measuredCardHeight: CGFloat = 0
    @State private var lastReportedInteractiveSize: CGSize = .zero
    /// IdlePeek is intentionally separate from event-card presentation. Without
    /// this explicit intent flag, an event closing while the cursor is still in
    /// the expanded hover frame can immediately fall through to the session list.
    @State private var idlePeekActive = false
    @State private var closingEvent: AttentionEvent?
    @State private var closingEventRevealSize: CGSize?
    @State private var closingEventFading = false
    @State private var pendingClosingEventClear: DispatchWorkItem?
    @State private var revealExpandedIsland = false
    @State private var idlePeekShowingAllSessions = false
    @State private var closingIdlePeek = false
    @State private var pendingIdlePeekCloseStart: DispatchWorkItem?
    @State private var pendingIdlePeekClose: DispatchWorkItem?
    @State private var idlePeekShellHeightOverride: CGFloat?
    @State private var idlePeekRevealHeightOverride: CGFloat?
    @State private var pendingIdlePeekRevealReset: DispatchWorkItem?
    /// Last shell height we observed while the idle peek was open. Lets the
    /// session-change handler animate from the previous height to the new
    /// one (the SwiftUI `.onChange` callback only sees the new sessions, so
    /// the old height has to be carried in `@State`). Reset to 0 when the
    /// peek closes so the next reopen doesn't animate from a stale value.
    @State private var lastObservedIdlePeekShellHeight: CGFloat = 0
    @State private var isClosingReveal = false
    @State private var selectedEventAction: EventCardAction?
    @State private var selectedIdleSessionID: String?
    @State private var idleToggleSelected = false
    @State private var idlePeekKeyboardMode = false

    private var rawHovering: Bool { !hoverReentrySuppressed && (hoveringNotchZone || hoveringIsland) }
    private let visibleIdleRows = 3
    // Triptych row: header(16) + 3 content lines(13 × 3) + 3 gaps(3 × 3) + vertical padding(6 × 2) = 76.
    // Must match the row's actual natural size so the shell sizing formula
    // in `idlePeekContentHeight` doesn't overshoot and leave visible empty
    // space between the last row and the container's bottom edge.
    private let idlePeekRowHeight: CGFloat = 76
    private let idlePeekRowSpacing: CGFloat = 4
    private let idlePeekToggleGap: CGFloat = 4
    private let idlePeekToggleHeight: CGFloat = 16
    private let idlePeekEmptyHeight: CGFloat = 58
    private let flatScreenIdleHandleWidth: CGFloat = 52
    private let flatScreenIdleHandleHeight: CGFloat = 4
    private let flatScreenIdleVisualHeight: CGFloat = 12
    private let flatScreenHoverWidth: CGFloat = 96
    private let flatScreenHoverHeight: CGFloat = 18
    private let flatScreenHandleTopInset: CGFloat = 6
    private let idlePeekOpenIntentDelay: TimeInterval = 0.18
    private let revealCloseDuration: TimeInterval = 0.36
    private let idlePeekCloseCommitDelay: TimeInterval = 0.16
    private let revealCloseCleanupDelay: TimeInterval = 0.60
    private let flatScreenRevealCloseCleanupDelay: TimeInterval = 0.42
    private var revealOpenAnimation: Animation {
        .timingCurve(0.18, 0.86, 0.24, 1.0, duration: 0.38)
    }
    private var revealCloseAnimation: Animation {
        .timingCurve(0.32, 0.0, 0.18, 1.0, duration: revealCloseDuration)
    }
    private var idlePeekResizeAnimation: Animation {
        .spring(response: 0.34, dampingFraction: 0.88)
    }
    private let idlePeekResizeDuration: TimeInterval = 0.34
    private var isIdleCloseCommitted: Bool {
        closingIdlePeek && isClosingReveal
    }

    // Hit zone sized to the physical notch (+ small margin).
    private var notchHoverWidth: CGFloat {
        screenHasNotch() ? physicalNotchSize().width + 20 : flatScreenHoverWidth
    }
    private var notchHoverHeight: CGFloat {
        screenHasNotch() ? physicalNotchSize().height : flatScreenHoverHeight
    }

    /// Size of the visible island shell right now.
    private var currentIslandSize: CGSize {
        let event = notchCenter.currentEvent ?? closingEvent
        let expanded = isExpandedPresentation(for: event)
        return resolvedIslandSize(for: event, expanded: expanded, hasNotch: screenHasNotch())
    }

    var body: some View {
        let _ = screenTracker.revision
        dynamicIsland()
            .frame(width: currentIslandSize.width, height: currentIslandSize.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            // Keep the hover trigger independent from the island's visual
            // layout so the wider non-notch trigger zone can't affect the
            // final centered position of the idle handle.
            Color.clear
                .frame(width: notchHoverWidth, height: notchHoverHeight)
                .contentShape(Rectangle())
                .onHover { setNotchHovering($0) }
        }
        .onAppear {
            reportInteractiveSize()
            setIslandHovering(hoverState.islandHovering)
        }
        .onChange(of: rawHovering) { _, hovering in
            applyHoverChange(to: hovering)
        }
        .onChange(of: hoverState.islandHovering) { _, hovering in
            // Detect genuine pointer entry here (not inside setIslandHovering)
            // because `hoveringIsland` may already be true from
            // `holdHoverForInternalInteraction`, which would early-return the
            // real hover-in before we get a chance to exit keyboard mode.
            if hovering, idlePeekKeyboardMode {
                idlePeekKeyboardMode = false
            }
            setIslandHovering(hovering)
        }
        .onChange(of: machine.state) { _, _ in
            reportInteractiveSize()
        }
        .onChange(of: activeTracker.sessions) { _, _ in
            if activeTracker.totalCount <= visibleIdleRows {
                idlePeekShowingAllSessions = false
                // ↑ Drives `handleIdlePeekRowsVisibilityChange`, which already
                // animates. Skip the session-driven animation below to avoid
                // double-firing.
                lastObservedIdlePeekShellHeight = idlePeekExpandedShellHeight(showingAllSessions: false)
                return
            }
            let newHeight = idlePeekExpandedShellHeight(showingAllSessions: idlePeekShowingAllSessions)
            let oldHeight = lastObservedIdlePeekShellHeight
            lastObservedIdlePeekShellHeight = newHeight

            let canAnimate = oldHeight > 0
                && abs(newHeight - oldHeight) > 0.5
                && idlePeekActive
                && revealExpandedIsland
                && notchCenter.currentEvent == nil
                && closingEvent == nil
            if canAnimate {
                animateIdlePeekShellResize(oldHeight: oldHeight, newHeight: newHeight)
            } else {
                reportInteractiveSize()
            }
        }
        .onChange(of: revealExpandedIsland) { _, expanded in
            // Reset the height baseline when the peek closes so the next
            // reopen doesn't animate from a stale snapshot. On reopen, seed
            // it with the current computed height so the first session-driven
            // change has a valid `oldHeight` to animate from.
            if expanded {
                lastObservedIdlePeekShellHeight = idlePeekExpandedShellHeight(
                    showingAllSessions: idlePeekShowingAllSessions
                )
            } else {
                lastObservedIdlePeekShellHeight = 0
            }
        }
        .onChange(of: notchCenter.currentEvent) { oldEvent, event in
            DiagnosticLogger.shared.info(
                "Island currentEvent changed event=\(event.map { $0.rawEventName } ?? "nil") hovering=\(effectiveHovering) notchHover=\(hoveringNotchZone) islandHover=\(hoveringIsland) state=\(String(describing: machine.state)) wasPeeking=\(wasPeekingOnEventArrival)"
            )
            if event != nil {
                resetIdlePeekRevealOverride()
                pendingIdlePeekOpen?.cancel()
                pendingIdlePeekOpen = nil
                pendingClosingEventClear?.cancel()
                pendingClosingEventClear = nil
                closingEvent = nil
                closingEventRevealSize = nil
                closingEventFading = false
                revealExpandedIsland = false
                isClosingReveal = false
                closingIdlePeek = false
                pendingIdlePeekCloseStart?.cancel()
                pendingIdlePeekCloseStart = nil
                pendingIdlePeekClose?.cancel()
                pendingIdlePeekClose = nil
                // Intentionally do NOT reset measuredCardHeight here. Resetting
                // forces the panel to fall back to the per-kind base height
                // until the next intrinsic measurement arrives — but SwiftUI's
                // `.onPreferenceChange` only fires when the aggregated value
                // actually changes. If the new card's intrinsic height happens
                // to equal the previous card's (very common between same-kind
                // cards in a queued burst), the listener never re-fires after
                // the reset, leaving `measuredCardHeight = 0` and clipping the
                // bottom action row behind the outer `.clipped()`. Keeping the
                // previous measurement as the initial value yields a pixel-
                // perfect frame when sizes match; if the new card differs, the
                // preference value changes and the listener updates normally.
                // Snapshot whether the user was already peeking when this event
                // arrived; close paths use this to decide whether to restore
                // the peek or suppress reentry.
                wasPeekingOnEventArrival = idlePeekActive && effectiveHovering
                idlePeekActive = false
                // Force a panel resize NOW: the state machine may already be
                // `.expanded` (idle peek was open), so `machine.show(.expanded)`
                // below is a no-op and `.onChange(of: machine.state)` won't
                // fire. Without this, the panel stays clamped to whatever the
                // idle peek was sized to until the event card's own intrinsic
                // measurement arrives — long enough that the bottom action
                // buttons render clipped.
                reportInteractiveSize(expandedOverride: true)
                schedulePanelExpansion {
                    machine.show(expanded: true)
                }
            } else {
                resetIdlePeekRevealOverride()
                pendingOpenWork?.cancel()
                pendingOpenWork = nil
                pendingIdlePeekOpen?.cancel()
                pendingIdlePeekOpen = nil
                if wasPeekingOnEventArrival && effectiveHovering {
                    // User was peeking before the event and is still hovering —
                    // bring the list card back instead of collapsing to idle.
                    measuredCardHeight = 0
                    idlePeekActive = true
                    isClosingReveal = false
                    pendingIdlePeekCloseStart?.cancel()
                    pendingIdlePeekCloseStart = nil
                    machine.restoreHoverPeek()
                    DispatchQueue.main.async {
                        withAnimation(revealOpenAnimation) {
                            revealExpandedIsland = true
                        }
                    }
                } else {
                    beginEventCardClose(from: oldEvent)
                }
                wasPeekingOnEventArrival = false
                reportInteractiveSize()
            }
        }
        .onPreferenceChange(NotchCardIntrinsicHeightKey.self) { h in
            handleCardIntrinsicHeightChange(h)
        }
        .onChange(of: idlePeekShowingAllSessions) { oldValue, newValue in
            handleIdlePeekRowsVisibilityChange(from: oldValue, to: newValue)
        }
        .onChange(of: notchCenter.currentEvent?.id) { _, _ in
            syncKeyboardSelection()
        }
        .onChange(of: idlePeekActive) { _, _ in
            syncKeyboardSelection()
        }
        .onChange(of: activeTracker.sessions) { _, _ in
            syncKeyboardSelection()
        }
        .onChange(of: keyboardState.generation) { _, _ in
            guard let action = keyboardState.action else { return }
            handleKeyboardAction(action)
        }
        .onChange(of: islandCommandState.generation) { _, _ in
            guard let command = islandCommandState.command else { return }
            handleIslandCommand(command)
        }
        .onChange(of: revealExpandedIsland) { _, _ in
            onKeyboardCaptureChange(shouldCaptureKeyboard)
        }
        .onChange(of: machine.state) { _, _ in
            onKeyboardCaptureChange(shouldCaptureKeyboard)
        }
    }

    // MARK: - Island

    @ViewBuilder
    private func dynamicIsland() -> some View {
        let event    = notchCenter.currentEvent ?? closingEvent
        let expanded = isExpandedPresentation(for: event)
        let hasNotch = screenHasNotch()

        let isRevealClosing = expanded && isClosingReveal
        let size = resolvedIslandSize(for: event, expanded: expanded, hasNotch: hasNotch)
        let isContentFading = isRevealClosing
            && closingEventFading
            && notchCenter.currentEvent == nil
        let botR = isRevealClosing
            ? NotchStateMachine.closedBottomCornerRadius
            : (expanded ? NotchStateMachine.openedBottomCornerRadius : NotchStateMachine.closedBottomCornerRadius)
        let shouldDrawShell = hasNotch || expanded || event != nil || (!hasNotch && machine.state == .idle)
        let idlePeekRevealHeight = event == nil && expanded && revealExpandedIsland
            ? min(size.height, idlePeekRevealHeightOverride ?? size.height)
            : size.height
        // Shell is kept at notch width until `revealExpandedIsland` flips true,
        // so both width and height animate in from the notch together — opening
        // and closing are symmetric "grow/shrink around the notch center."
        let compactShell = expanded && !revealExpandedIsland
        let visualWidth = compactShell
            ? min(size.width, collapsedRevealWidth(hasNotch: hasNotch))
            : size.width
        let revealHeight = expanded && !revealExpandedIsland
            ? min(size.height, collapsedRevealHeight(hasNotch: hasNotch))
            : idlePeekRevealHeight
        let revealMaskBottomRadius = botR

        // Keep the shell itself at full target size and reveal it with a top-
        // anchored mask. Animating the shell's own frame height can read as a
        // center-origin resize in SwiftUI; animating only the mask makes the
        // island feel like it slides out from the notch.
        ZStack(alignment: .top) {
            Group {
                if shouldDrawShell {
                    if hasNotch {
                        NotchShape(topCornerRadius: 0, bottomCornerRadius: botR)
                            .fill(Color.black)
                    } else if expanded || event != nil {
                        NotchShape(topCornerRadius: 0, bottomCornerRadius: botR)
                            .fill(Color.black)
                    } else {
                        Capsule()
                            .fill(Color.white.opacity(0.26))
                            .frame(
                                width: flatScreenIdleHandleWidth,
                                height: flatScreenIdleHandleHeight,
                                alignment: .top
                            )
                            .padding(.top, flatScreenHandleTopInset)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(width: visualWidth, height: size.height, alignment: .top)
            .mask(shellRevealMask(
                width: visualWidth,
                height: size.height,
                revealHeight: revealHeight,
                bottomCornerRadius: revealMaskBottomRadius
            ))
            .animation(revealExpandedIsland ? revealOpenAnimation : revealCloseAnimation, value: revealExpandedIsland)

            islandContent(event: event, expanded: expanded)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
                .mask(topRevealMask(
                    width: visualWidth,
                    height: size.height,
                    revealHeight: revealHeight,
                    bottomCornerRadius: revealMaskBottomRadius
                ))
                .animation(revealExpandedIsland ? revealOpenAnimation : revealCloseAnimation, value: revealExpandedIsland)
                .offset(y: isContentFading ? -12 : 0)
                .opacity(isContentFading ? 0 : 1)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
    }

    /// Shared transition used for every expanded card (event cards + idle peek
    /// list). Applied on each inner branch so a single animation runs per swap.
    ///
    /// Insertion = gentle scale-from-notch + fade. Removal = opacity only, fast:
    /// the shell's own close animation (mask + width) handles the "shrink back
    /// into the notch" motion, so if content also scaled on its way out its
    /// bottom would ride *up* as the mask slides *down* — producing a one-frame
    /// bulge that reads as "content flashing outside the container." Fading
    /// content quickly and letting the shell finish alone keeps the collapse
    /// clean.
    private var expandedCardTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                .animation(.easeOut(duration: 0.40).delay(0.14)),
            removal: .opacity.animation(.easeIn(duration: 0.18))
        )
    }

    private var idlePeekCardTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.12)),
            removal: .opacity.animation(.easeIn(duration: 0.14))
        )
    }

    @ViewBuilder
    private func islandContent(event: AttentionEvent?, expanded: Bool) -> some View {
        if expanded {
            ZStack(alignment: .top) {
                if let event {
                    expandedContent(for: event)
                        .transition(expandedCardTransition)
                } else {
                    IdlePeekCard(
                        activeTracker: activeTracker,
                        showingAllSessions: $idlePeekShowingAllSessions,
                        keyboardSelectedSessionID: idlePeekKeyboardMode ? selectedIdleSessionID : nil,
                        keyboardSelectsToggle: idlePeekKeyboardMode && idleToggleSelected,
                        visibleRows: visibleIdleRows,
                        rowHeight: idlePeekRowHeight,
                        rowSpacing: idlePeekRowSpacing,
                        contentHeight: idlePeekHeight
                    ) { session in
                        focusTerminal(for: session)
                    } onInternalInteraction: {
                        holdHoverForInternalInteraction()
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    .transition(idlePeekCardTransition)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, expandedContentTopPadding)
            .padding(.bottom, expandedContentBottomPadding(event: event))
        } else if let event, machine.state == .compact {
            // Only show the compact pill when the state machine is actually in
            // .compact. Omitting `.idle` here prevents a brief pill flash when
            // the user dismisses an expanded card (state goes .expanded → .idle,
            // and the event hasn't been cleared yet on the same tick).
            compactContent(for: event)
                .padding(.horizontal, 12)
                .transition(.opacity.animation(.easeOut(duration: 0.18)))
        }
        // Idle + no hover → empty (shell matches physical notch)
    }

    // MARK: - Sizes

    private func islandSize(for event: AttentionEvent?, expanded: Bool, hasNotch: Bool) -> CGSize {
        if expanded {
            let h: CGFloat
            if let event {
                // Prefer the card's measured intrinsic height (dynamic: short
                // content shrinks, long content grows up to the max cap). Fall
                // back to per-kind baseline until the first measurement arrives.
                let fallbackBase: CGFloat
                let maxAllowed: CGFloat
                switch event.kind {
                // Fallback bases are slightly over the typical "small content"
                // size so the first frame before measurement arrives doesn't
                // clip the bottom buttons. maxAllowed is a safety upper bound
                // — actual height still follows measured content.
                // Fallback used for a single frame before the measurement key
                // fires. Pick a value close to the typical final height so the
                // first frame isn't obviously wrong while we wait; measurement
                // takes over within ~1 frame.
                // Permission card grows with content so long commands / diffs
                // / todo lists aren't clipped behind a hard-coded ceiling. Hard
                // cap by the visible screen height so a pathological heredoc
                // doesn't push past the menu bar; actual height still follows
                // the measured card (min(maxAllowed, intrinsic + chrome)).
                case .permissionRequest:
                    fallbackBase = 200
                    let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
                    maxAllowed = max(420, screenHeight - 120)
                case .taskFailed:        fallbackBase = 180; maxAllowed = 420
                case .waitingInput:      fallbackBase = 200; maxAllowed = 440
                case .taskDone:          fallbackBase = 200; maxAllowed = 420
                case .sessionStart:      fallbackBase = 160; maxAllowed = 420
                case .activityPulse, .sessionEnd:
                    fallbackBase = idlePeekHeight; maxAllowed = 280
                }
                let chrome = expandedContentTopPadding + 14  // top + bottom card padding
                let intrinsic = measuredCardHeight > 0 ? measuredCardHeight : fallbackBase
                h = min(maxAllowed, intrinsic + chrome)
            } else {
                h = idlePeekShellHeightOverride ?? idlePeekExpandedShellHeight(showingAllSessions: idlePeekShowingAllSessions)
            }
            // Detailed mode widens every expanded panel (idle peek + all
            // event cards) so long command previews, diffs, and permission
            // payloads have room to breathe without wrapping. When the
            // preference is off, everyone shares the compact 440pt width.
            let w = idlePeekDetailedRows
                ? NotchStateMachine.expandedDetailedWidth
                : NotchStateMachine.expandedWidth
            return CGSize(width: w, height: h)
        }

        // Compact with event: small pill showing summary.
        // Only return the pill size when the state machine is genuinely in
        // .compact — during dismissal (state=.idle but event hasn't cleared on
        // the same tick), treat the island as idle to avoid a two-step shrink
        // (expanded → pill → idle) which reads as a visual "jump".
        if event != nil && machine.state == .compact {
            if hasNotch {
                let phys = physicalNotchSize()
                return CGSize(width: max(phys.width, 220), height: phys.height)
            }
            return CGSize(width: NotchStateMachine.compactWidth, height: NotchStateMachine.compactHeight)
        }

        // Idle: match physical notch exactly so the island blends in
        if hasNotch {
            return physicalNotchSize()
        }
        return CGSize(width: flatScreenIdleHandleWidth, height: flatScreenIdleVisualHeight)
    }

    private func resolvedIslandSize(for event: AttentionEvent?, expanded: Bool, hasNotch: Bool) -> CGSize {
        let measuredSize = islandSize(for: event, expanded: expanded, hasNotch: hasNotch)
        guard expanded else { return measuredSize }
        if event != nil, isClosingReveal, let closingEventRevealSize {
            return closingEventRevealSize
        }
        return measuredSize
    }

    private func interactiveCanvasSize(for event: AttentionEvent?, expanded: Bool, hasNotch: Bool) -> CGSize {
        // Treat as idle when state is .idle — even if `event` is still set
        // momentarily during a dismissal. Prevents a two-step window shrink.
        let treatAsIdle = machine.state == .idle && !expanded
        if !treatAsIdle, expanded || event != nil {
            return islandSize(for: event, expanded: expanded, hasNotch: hasNotch)
        }

        if hasNotch {
            let notch = physicalNotchSize()
            return CGSize(width: notch.width + 20, height: notch.height)
        }
        return CGSize(width: flatScreenIdleHandleWidth, height: flatScreenIdleVisualHeight)
    }

    private var idlePeekHeight: CGFloat {
        idlePeekContentHeight(showingAllSessions: idlePeekShowingAllSessions)
    }

    private var idlePeekShowsToggle: Bool {
        activeTracker.totalCount > visibleIdleRows || idlePeekShowingAllSessions
    }

    private var maxIdlePeekHeight: CGFloat {
        guard let screen = NSScreen.main else { return 720 }
        return max(280, screen.visibleFrame.height - 28)
    }

    private func idlePeekContentHeight(showingAllSessions: Bool) -> CGFloat {
        let sessions = activeTracker.sessions
        let rowCount = showingAllSessions
            ? sessions.count
            : min(sessions.count, visibleIdleRows)
        guard rowCount > 0 else { return idlePeekEmptyHeight }

        let rowsHeight: CGFloat
        let visibleSessions = Array(sessions.prefix(rowCount))
        rowsHeight = visibleSessions.reduce(0) { sum, session in
            sum + IdlePeekLayout.rowHeight(
                for: session,
                baseHeight: idlePeekRowHeight,
                detailedMode: idlePeekDetailedRows
            )
        }
        let rowGaps = CGFloat(max(0, rowCount - 1)) * idlePeekRowSpacing
        let toggleHeight = idlePeekShowsToggle ? idlePeekToggleGap + idlePeekToggleHeight : 0
        return rowsHeight + rowGaps + toggleHeight
    }

    private func idlePeekExpandedShellHeight(showingAllSessions: Bool) -> CGFloat {
        let chrome = expandedContentTopPadding + expandedContentBottomPadding(event: nil)
        return min(maxIdlePeekHeight, idlePeekContentHeight(showingAllSessions: showingAllSessions) + chrome)
    }

    private var expandedContentTopPadding: CGFloat {
        screenHasNotch() ? max(physicalNotchSize().height + 2, 30) : 10
    }

    private func expandedContentBottomPadding(event: AttentionEvent?) -> CGFloat {
        if event != nil {
            return 14
        }
        // Rows now force themselves to the exact height the shell estimate
        // expects (see `IdlePeekLayout.rowHeight` + `.frame(height:)` inside
        // `IdlePeekCard`), so there's no estimate/actual slack. Bottom
        // padding is a clean 18pt mirroring the horizontal padding.
        return idlePeekShowsToggle ? 4 : 18
    }

    private func collapsedRevealHeight(hasNotch: Bool) -> CGFloat {
        if hasNotch {
            return physicalNotchSize().height
        }
        return 1
    }

    private func collapsedRevealWidth(hasNotch: Bool) -> CGFloat {
        if hasNotch {
            return physicalNotchSize().width
        }
        return 1
    }

    private func topRevealMask(
        width: CGFloat,
        height: CGFloat,
        revealHeight: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> some View {
        TopRevealMaskShape(revealHeight: max(0, min(height, revealHeight)), bottomCornerRadius: bottomCornerRadius)
            .frame(width: width, height: height, alignment: .top)
    }

    @ViewBuilder
    private func shellRevealMask(
        width: CGFloat,
        height: CGFloat,
        revealHeight: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> some View {
        topRevealMask(
            width: width,
            height: height,
            revealHeight: revealHeight,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    private var expandedContentTopInsetDelta: CGFloat {
        max(0, expandedContentTopPadding - 14)
    }

    private func reportInteractiveSize(expandedOverride: Bool? = nil) {
        let event = notchCenter.currentEvent ?? closingEvent
        let expanded = expandedOverride ?? isExpandedPresentation(for: event)
        let hasNotch = screenHasNotch()
        let size: CGSize
        if expandedOverride != false,
           isClosingReveal,
           closingEvent != nil,
           let closingEventRevealSize {
            size = closingEventRevealSize
        } else {
            size = interactiveCanvasSize(for: event, expanded: expanded, hasNotch: hasNotch)
        }
        let normalized = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard abs(normalized.width - lastReportedInteractiveSize.width) > 0.5
                || abs(normalized.height - lastReportedInteractiveSize.height) > 0.5 else {
            return
        }
        lastReportedInteractiveSize = normalized
        DiagnosticLogger.shared.verbose(
            "Island report size w=\(Int(normalized.width)) h=\(Int(normalized.height)) event=\(event?.rawEventName ?? "nil") expanded=\(expanded) override=\(expandedOverride.map(String.init(describing:)) ?? "nil") hovering=\(self.effectiveHovering) state=\(String(describing: self.machine.state))"
        )

        let callback = onInteractiveSizeChange
        // Avoid mutating the NSPanel frame in the same SwiftUI/AppKit
        // constraint pass that produced the measurement.
        DispatchQueue.main.async {
            callback(normalized)
        }
    }

    private func handleCardIntrinsicHeightChange(_ height: CGFloat) {
        guard height > 0, abs(height - measuredCardHeight) > 0.5 else { return }
        let previous = measuredCardHeight
        measuredCardHeight = height
        lastCardHeightChangeAt = Date()
        DiagnosticLogger.shared.verbose(
            "Card intrinsic h=\(Int(height)) prev=\(Int(previous)) event=\(self.notchCenter.currentEvent?.rawEventName ?? "nil") hovering=\(self.effectiveHovering) state=\(String(describing: self.machine.state))"
        )
        reportInteractiveSize()
    }

    private func handleIdlePeekRowsVisibilityChange(from oldValue: Bool, to newValue: Bool) {
        let oldHeight = idlePeekExpandedShellHeight(showingAllSessions: oldValue)
        let newHeight = idlePeekExpandedShellHeight(showingAllSessions: newValue)
        animateIdlePeekShellResize(oldHeight: oldHeight, newHeight: newHeight)
    }

    /// Animates the idle-peek shell from `oldHeight` to `newHeight` using the
    /// override mechanism: the panel snaps to whichever is larger so SwiftUI
    /// has enough canvas, the SwiftUI reveal mask animates from old to new,
    /// then both overrides reset after `idlePeekResizeDuration`. Used by both
    /// the show-all toggle and active-session count changes (tools starting
    /// or finishing) so the panel resizes smoothly in both cases.
    private func animateIdlePeekShellResize(oldHeight: CGFloat, newHeight: CGFloat) {
        pendingIdlePeekRevealReset?.cancel()
        pendingIdlePeekRevealReset = nil

        guard notchCenter.currentEvent == nil,
              closingEvent == nil,
              idlePeekActive,
              revealExpandedIsland else {
            idlePeekRevealHeightOverride = nil
            reportInteractiveSize()
            return
        }

        if newHeight < oldHeight {
            idlePeekShellHeightOverride = oldHeight
        } else {
            idlePeekShellHeightOverride = nil
        }
        idlePeekRevealHeightOverride = oldHeight
        reportInteractiveSize()

        DispatchQueue.main.async {
            withAnimation(idlePeekResizeAnimation) {
                idlePeekRevealHeightOverride = newHeight
            }
        }

        let resetWork = DispatchWorkItem {
            pendingIdlePeekRevealReset = nil
            idlePeekShellHeightOverride = nil
            idlePeekRevealHeightOverride = nil
            reportInteractiveSize()
        }
        pendingIdlePeekRevealReset = resetWork
        DispatchQueue.main.asyncAfter(deadline: .now() + idlePeekResizeDuration, execute: resetWork)
    }

    private func resetIdlePeekRevealOverride() {
        pendingIdlePeekRevealReset?.cancel()
        pendingIdlePeekRevealReset = nil
        idlePeekShellHeightOverride = nil
        idlePeekRevealHeightOverride = nil
    }

    private func isExpandedPresentation(for event: AttentionEvent?) -> Bool {
        // When an event disappears, `machine.state` can still be `.expanded`
        // for the current render tick. Treat the idle peek as expanded only
        // while the pointer is actually hovering, otherwise the card briefly
        // "falls through" to IdlePeekCard before closing.
        if event == nil {
            return closingIdlePeek || (idlePeekActive && (effectiveHovering || rawHovering))
        }
        return machine.state == .expanded || effectiveHovering
    }

    private func focusTerminal(for session: ActiveSession) {
        DiagnosticLogger.shared.info(
            "Island focus action session key=\(session.focusKey) pid=\(session.pid.map(String.init) ?? "-") tty=\(session.tty ?? "-") terminal=\(session.terminalName ?? "-") tabID=\(session.terminalTabID ?? "-") stableID=\(session.terminalStableID ?? "-") cwd=\(session.projectPath ?? "-")"
        )
        let focusKey = session.focusKey
        let pid = session.pid
        let tty = session.tty
        let projectPath = session.projectPath
        let terminalName = session.terminalName
        let terminalSocket = session.terminalSocket
        let terminalWindowID = session.terminalWindowID
        let terminalTabID = session.terminalTabID
        let terminalStableID = session.terminalStableID
        let sessionId = session.sessionId
        closeIslandBeforeFocus()
        Task(priority: .userInitiated) {
            _ = await TerminalFocusCoordinator.shared.focus(
                cacheKey: focusKey,
                pid: pid,
                tty: tty,
                projectPath: projectPath,
                terminalName: terminalName,
                terminalSocket: terminalSocket,
                terminalWindowID: terminalWindowID,
                terminalTabID: terminalTabID,
                stableTerminalID: terminalStableID,
                sessionId: sessionId
            )
        }
    }

    private func focusTerminal(for event: AttentionEvent) {
        let focusContext = activeTracker.focusContext(for: event)
        DiagnosticLogger.shared.info(
            "Island focus action event key=\(event.provider.rawValue):\(event.sessionId) raw=\(event.rawEventName) pid=\(focusContext.pid.map(String.init) ?? "-") tty=\(focusContext.tty ?? "-") terminal=\(focusContext.terminalName ?? "-") tabID=\(focusContext.terminalTabID ?? "-") stableID=\(focusContext.terminalStableID ?? "-") cwd=\(focusContext.projectPath ?? "-")"
        )
        let focusKey = "\(event.provider.rawValue):\(event.sessionId)"
        let sessionId = event.sessionId
        closeIslandBeforeFocus(eventId: event.id)
        Task(priority: .userInitiated) {
            _ = await TerminalFocusCoordinator.shared.focus(
                cacheKey: focusKey,
                pid: focusContext.pid,
                tty: focusContext.tty,
                projectPath: focusContext.projectPath,
                terminalName: focusContext.terminalName,
                terminalSocket: focusContext.terminalSocket,
                terminalWindowID: focusContext.terminalWindowID,
                terminalTabID: focusContext.terminalTabID,
                stableTerminalID: focusContext.terminalStableID,
                sessionId: sessionId
            )
        }
    }

    private func closeIslandBeforeFocus(eventId: UUID? = nil) {
        pendingOpenWork?.cancel()
        pendingOpenWork = nil
        pendingIdlePeekOpen?.cancel()
        pendingIdlePeekOpen = nil
        resetIdlePeekRevealOverride()
        pendingClosingEventClear?.cancel()
        pendingClosingEventClear = nil
        closingEvent = nil
        closingEventFading = false
        pendingHoverReentryReset?.cancel()
        pendingHoverReentryReset = nil
        hoveringIsland = false
        hoveringNotchZone = false
        if let eventId {
            flushHoverLeave()
            // `dismiss` drives `onChange(currentEvent)` → `machine.hide()`, so
            // state and event clear together without the intermediate one-frame
            // mismatch that produced the flicker on dismissal.
            notchCenter.dismiss(id: eventId)
        } else {
            suppressHoverReentry()
        }
    }

    private func setNotchHovering(_ hovering: Bool) {
        DiagnosticLogger.shared.verbose(
            "Island notch hover=\(hovering) suppressed=\(self.hoverReentrySuppressed) event=\(self.notchCenter.currentEvent?.rawEventName ?? "nil") state=\(String(describing: self.machine.state))"
        )
        if hovering {
            guard !isIdleCloseCommitted else { return }
            guard !hoverReentrySuppressed else { return }
            // Real pointer entered: hand control back to the mouse so a later
            // pointer-leave collapses the peek normally instead of being held
            // open by the keyboard-mode short-circuit.
            if idlePeekKeyboardMode {
                idlePeekKeyboardMode = false
            }
            resumeIdlePeekCloseIfNeeded()
            hoveringNotchZone = true
            if notchCenter.currentEvent != nil || closingEvent != nil {
                return
            }
            scheduleIdlePeekOpenIfNeeded()
        } else {
            if shouldHoldHoverLeave() {
                startHoverGuardCheck()
                return
            }
            pendingIdlePeekOpen?.cancel()
            pendingIdlePeekOpen = nil
            hoveringNotchZone = false
        }
    }

    private func setIslandHovering(_ hovering: Bool) {
        guard hoveringIsland != hovering else { return }
        DiagnosticLogger.shared.verbose(
            "Island body hover=\(hovering) suppressed=\(self.hoverReentrySuppressed) event=\(self.notchCenter.currentEvent?.rawEventName ?? "nil") state=\(String(describing: self.machine.state))"
        )
        if hovering {
            guard !isIdleCloseCommitted else { return }
            guard !hoverReentrySuppressed else { return }
            resumeIdlePeekCloseIfNeeded()
            hoveringIsland = true
            if notchCenter.currentEvent != nil || closingEvent != nil {
                return
            }
            scheduleIdlePeekOpenIfNeeded()
        } else {
            if shouldHoldHoverLeave() {
                startHoverGuardCheck()
                return
            }
            pendingIdlePeekOpen?.cancel()
            pendingIdlePeekOpen = nil
            hoveringIsland = false
        }
    }

    private func scheduleIdlePeekOpenIfNeeded() {
        guard notchCenter.currentEvent == nil,
              closingEvent == nil,
              !idlePeekActive,
              !closingIdlePeek,
              !isIdleCloseCommitted else { return }
        guard pendingIdlePeekOpen == nil else { return }

        let work = DispatchWorkItem {
            pendingIdlePeekOpen = nil
            guard !hoverReentrySuppressed,
                  notchCenter.currentEvent == nil,
                  closingEvent == nil,
                  !idlePeekActive,
                  rawHovering else {
                return
            }
            idlePeekActive = true
            idlePeekKeyboardMode = false
            schedulePanelExpansion {
                // Hover intent was stable for long enough to count as an
                // intentional idle-list peek.
            }
        }
        pendingIdlePeekOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idlePeekOpenIntentDelay, execute: work)
    }

    private func applyHoverChange(to hovering: Bool) {
        if hovering {
            pendingHoverLeave?.cancel()
            pendingHoverLeave = nil
            pendingInternalHoverGuardCheck?.cancel()
            pendingInternalHoverGuardCheck = nil
            pendingNearbyHoverGuardCheck?.cancel()
            pendingNearbyHoverGuardCheck = nil
            internalInteractionHoverGuardSize = nil
            guard !effectiveHovering else { return }
            effectiveHovering = true
            deliverHover(true)
            return
        }
        scheduleHoverLeave(initialDelay: hoverLeaveDebounce)
    }

    private func scheduleHoverLeave(initialDelay: TimeInterval) {
        pendingHoverLeave?.cancel()
        let work = DispatchWorkItem {
            pendingHoverLeave = nil
            // Rehovered during the debounce — abandon.
            guard !rawHovering else { return }
            // Keyboard-opened peeks aren't anchored to the pointer. Don't let
            // pointer-leave (which is always "left" in this mode) collapse the
            // peek — ESC or the shortcut is the intended way out.
            if idlePeekKeyboardMode, idlePeekActive {
                return
            }
            if let guardSize = activeHoverGuardSize() {
                if mouseIsInsideTopCenteredRect(size: guardSize) {
                    scheduleHoverLeave(initialDelay: hoverLeaveDebounce)
                    return
                }
                internalInteractionHoverGuardSize = nil
            }
            // Card is mid-animation (toggle, Markdown relayout, session churn)
            // and the SwiftUI frame may be moving out from under the cursor.
            // Wait until the measurement settles before actually collapsing.
            if let last = lastCardHeightChangeAt {
                let elapsed = Date().timeIntervalSince(last)
                if elapsed < cardMeasurementSettleWindow {
                    scheduleHoverLeave(initialDelay: cardMeasurementSettleWindow - elapsed)
                    return
                }
            }
            guard effectiveHovering else { return }
            effectiveHovering = false
            deliverHover(false)
        }
        pendingHoverLeave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay, execute: work)
    }

    private func holdHoverForInternalInteraction() {
        internalInteractionHoverGuardSize = CGSize(
            width: max(currentIslandSize.width, lastReportedInteractiveSize.width),
            height: max(currentIslandSize.height, lastReportedInteractiveSize.height)
        )
        lastCardHeightChangeAt = Date()
        hoveringIsland = true
        pendingHoverLeave?.cancel()
        pendingHoverLeave = nil
        pendingIdlePeekCloseStart?.cancel()
        pendingIdlePeekCloseStart = nil
        pendingIdlePeekClose?.cancel()
        pendingIdlePeekClose = nil
        pendingIdlePeekOpen?.cancel()
        pendingIdlePeekOpen = nil
        resetIdlePeekRevealOverride()
        closingIdlePeek = false
        if !effectiveHovering {
            effectiveHovering = true
            deliverHover(true)
        }
        startHoverGuardCheck()
    }

    private func shouldHoldHoverLeave() -> Bool {
        guard let guardSize = activeHoverGuardSize() else { return false }
        return mouseIsInsideTopCenteredRect(size: guardSize)
    }

    private func startHoverGuardCheck() {
        pendingInternalHoverGuardCheck?.cancel()
        pendingNearbyHoverGuardCheck?.cancel()
        guard activeHoverGuardSize() != nil else { return }

        let work = DispatchWorkItem {
            pendingInternalHoverGuardCheck = nil
            pendingNearbyHoverGuardCheck = nil
            guard let nextGuardSize = activeHoverGuardSize() else { return }
            if mouseIsInsideTopCenteredRect(size: nextGuardSize) {
                startHoverGuardCheck()
                return
            }
            // Keyboard-driven peek: pointer is irrelevant, don't tear down
            // hover flags just because the mouse happens to be elsewhere.
            if idlePeekKeyboardMode, idlePeekActive {
                return
            }

            internalInteractionHoverGuardSize = nil
            hoveringIsland = false
            hoveringNotchZone = false
        }
        pendingInternalHoverGuardCheck = work
        pendingNearbyHoverGuardCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func activeHoverGuardSize() -> CGSize? {
        if let internalInteractionHoverGuardSize {
            return CGSize(
                width: max(internalInteractionHoverGuardSize.width, currentIslandSize.width, lastReportedInteractiveSize.width),
                height: max(internalInteractionHoverGuardSize.height, currentIslandSize.height, lastReportedInteractiveSize.height)
            )
        }

        guard notchCenter.currentEvent == nil,
              closingEvent == nil,
              idlePeekActive || effectiveHovering || closingIdlePeek else {
            return nil
        }

        // For ordinary idle-peek hover, stay close to the visible shell. The
        // AppKit window can remain taller during deferred shrink animations;
        // using that canvas height here makes the invisible hover area feel
        // detached from what the user sees.
        return currentIslandSize
    }

    private func mouseIsInsideTopCenteredRect(size: CGSize) -> Bool {
        guard let screen = notchTargetScreen() else { return false }
        let width = max(1, ceil(size.width))
        let height = max(1, ceil(size.height))
        let rect = CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        return rect.contains(NSEvent.mouseLocation)
    }

    /// Force `effectiveHovering` to false immediately, bypassing the debounce.
    /// Called from user-initiated close paths so the card's removal transition
    /// actually plays — if we waited for the debounce, the SwiftUI presentation
    /// would stay "expanded" and briefly cross-fade into IdlePeekCard instead.
    private func flushHoverLeave() {
        pendingHoverLeave?.cancel()
        pendingHoverLeave = nil
        pendingInternalHoverGuardCheck?.cancel()
        pendingInternalHoverGuardCheck = nil
        pendingNearbyHoverGuardCheck?.cancel()
        pendingNearbyHoverGuardCheck = nil
        internalInteractionHoverGuardSize = nil
        guard effectiveHovering else { return }
        effectiveHovering = false
        deliverHover(false)
    }

    private func deliverHover(_ hovering: Bool) {
        if !hovering, notchCenter.currentEvent == nil {
            beginIdlePeekClose()
        } else if hovering {
            pendingIdlePeekCloseStart?.cancel()
            pendingIdlePeekCloseStart = nil
            pendingIdlePeekClose?.cancel()
            pendingIdlePeekClose = nil
            closingIdlePeek = false
        }
        machine.handleHover(hovering)
        reportInteractiveSize()
        if hovering {
            notchCenter.pauseAutoDismissForHover()
        } else {
            notchCenter.resumeAutoDismissAfterHover()
        }
    }

    private func schedulePanelExpansion(_ expand: @escaping () -> Void) {
        pendingOpenWork?.cancel()
        pendingIdlePeekClose?.cancel()
        pendingIdlePeekClose = nil
        pendingIdlePeekCloseStart?.cancel()
        pendingIdlePeekCloseStart = nil
        closingIdlePeek = false
        isClosingReveal = false
        revealExpandedIsland = false
        // If the user reopens while a previous close is still fading content
        // out, `closingEventFading` can still be `true` — which would force the
        // newly opened card to render at opacity 0 (black shell, empty body).
        // Reset before the expand animation begins.
        closingEventFading = false
        closingEventRevealSize = nil

        // Phase 1: resize the AppKit window/canvas while the visible island is
        // still compact, so the SwiftUI expansion has a stable centered stage.
        reportInteractiveSize(expandedOverride: true)

        // Phase 2: start the island shape/content animation on the next frame.
        let work = DispatchWorkItem {
            expand()
            reportInteractiveSize()
            pendingOpenWork = nil
            DispatchQueue.main.async {
                withAnimation(revealOpenAnimation) {
                    revealExpandedIsland = true
                }
            }
        }
        pendingOpenWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045, execute: work)
    }

    private func resumeIdlePeekCloseIfNeeded() {
        guard closingIdlePeek else { return }
        pendingIdlePeekClose?.cancel()
        pendingIdlePeekClose = nil
        pendingIdlePeekCloseStart?.cancel()
        pendingIdlePeekCloseStart = nil
        isClosingReveal = false
        closingIdlePeek = false
        closingEventFading = false
        idlePeekActive = true
        withAnimation(revealOpenAnimation) {
            revealExpandedIsland = true
        }
    }

    private func startRevealCloseAnimation() {
        isClosingReveal = true
        withAnimation(revealCloseAnimation) {
            revealExpandedIsland = false
        }
        // Fade the card content out quickly (faster than the shell collapses)
        // so it can't bulge outside the shell's shrinking mask. The black
        // shell itself keeps its full close animation (mask height + width
        // retracting toward the notch). Same path for event cards and the
        // idle-peek list.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            closingEventFading = true
        }
    }

    private func beginIdlePeekClose(force: Bool = false) {
        guard idlePeekActive || closingIdlePeek else {
            revealExpandedIsland = false
            idlePeekKeyboardMode = false
            return
        }

        if force {
            pendingHoverLeave?.cancel()
            pendingHoverLeave = nil
            if effectiveHovering {
                effectiveHovering = false
                machine.handleHover(false)
                notchCenter.resumeAutoDismissAfterHover()
            }
        }

        pendingIdlePeekCloseStart?.cancel()
        pendingIdlePeekClose?.cancel()
        pendingIdlePeekClose = nil
        closingIdlePeek = true
        let startWork = DispatchWorkItem {
            pendingIdlePeekCloseStart = nil
            guard force || !rawHovering else {
                resumeIdlePeekCloseIfNeeded()
                return
            }

            idlePeekKeyboardMode = false
            closingEventFading = false
            hoverReentrySuppressed = true
            pendingHoverReentryReset?.cancel()
            pendingHoverReentryReset = nil
            internalInteractionHoverGuardSize = nil
            pendingInternalHoverGuardCheck?.cancel()
            pendingInternalHoverGuardCheck = nil
            pendingNearbyHoverGuardCheck?.cancel()
            pendingNearbyHoverGuardCheck = nil
            hoveringIsland = false
            hoveringNotchZone = false
            startRevealCloseAnimation()

            let cleanupWork = DispatchWorkItem {
                pendingIdlePeekClose = nil
                idlePeekActive = false
                closingIdlePeek = false
                isClosingReveal = false
                closingEventFading = false
                hoverReentrySuppressed = false
                idlePeekKeyboardMode = false
                measuredCardHeight = 0
                reportInteractiveSize(expandedOverride: false)
            }
            pendingIdlePeekClose = cleanupWork
            DispatchQueue.main.asyncAfter(deadline: .now() + closeCleanupDelay(), execute: cleanupWork)
        }
        pendingIdlePeekCloseStart = startWork
        DispatchQueue.main.asyncAfter(deadline: .now() + idlePeekCloseCommitDelay, execute: startWork)
    }

    private func suppressHoverReentry(for seconds: TimeInterval = 1.2) {
        pendingHoverReentryReset?.cancel()
        pendingIdlePeekCloseStart?.cancel()
        pendingIdlePeekCloseStart = nil
        pendingIdlePeekClose?.cancel()
        pendingIdlePeekClose = nil
        pendingIdlePeekOpen?.cancel()
        pendingIdlePeekOpen = nil
        closingIdlePeek = false
        isClosingReveal = false
        hoverReentrySuppressed = true
        hoveringIsland = false
        hoveringNotchZone = false
        pendingOpenWork?.cancel()
        pendingOpenWork = nil
        // User-initiated close — collapse immediately so SwiftUI can play the
        // card's removal transition instead of briefly cross-fading to peek.
        startRevealCloseAnimation()
        flushHoverLeave()

        let work = DispatchWorkItem {
            hoverReentrySuppressed = false
            pendingHoverReentryReset = nil
        }
        pendingHoverReentryReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func beginEventCardClose(from event: AttentionEvent?) {
        if let event {
            let measuredCloseSize = islandSize(for: event, expanded: true, hasNotch: screenHasNotch())
            closingEventRevealSize = CGSize(
                width: max(measuredCloseSize.width, lastReportedInteractiveSize.width),
                height: max(measuredCloseSize.height, lastReportedInteractiveSize.height)
            )
            closingEvent = event
        } else {
            closingEventRevealSize = nil
        }
        idlePeekActive = false
        pendingOpenWork?.cancel()
        pendingOpenWork = nil
        pendingIdlePeekOpen?.cancel()
        pendingIdlePeekOpen = nil
        resetIdlePeekRevealOverride()
        pendingIdlePeekClose?.cancel()
        pendingIdlePeekClose = nil
        pendingIdlePeekCloseStart?.cancel()
        pendingIdlePeekCloseStart = nil
        closingIdlePeek = false
        isClosingReveal = false
        pendingHoverLeave?.cancel()
        pendingHoverLeave = nil
        pendingHoverReentryReset?.cancel()
        pendingHoverReentryReset = nil
        hoveringIsland = false
        hoveringNotchZone = false
        effectiveHovering = false
        hoverReentrySuppressed = true
        // Reset fade flag before startRevealCloseAnimation() flips it true
        // under an animation. Otherwise a stale `true` from a previous cycle
        // would short-circuit the fade transition.
        closingEventFading = false
        startRevealCloseAnimation()

        guard event != nil else {
            machine.hide()
            isClosingReveal = false
            closingEventRevealSize = nil
            measuredCardHeight = 0
            scheduleHoverReentryReset()
            return
        }

        let clearWork = DispatchWorkItem {
            pendingClosingEventClear = nil
            machine.hide()
            closingEvent = nil
            closingEventRevealSize = nil
            closingEventFading = false
            revealExpandedIsland = false
            isClosingReveal = false
            measuredCardHeight = 0
            reportInteractiveSize(expandedOverride: false)
        }
        pendingClosingEventClear = clearWork
        DispatchQueue.main.asyncAfter(deadline: .now() + closeCleanupDelay(), execute: clearWork)
        scheduleHoverReentryReset()
    }

    private func closeCleanupDelay() -> TimeInterval {
        screenHasNotch() ? revealCloseCleanupDelay : flatScreenRevealCloseCleanupDelay
    }

    private func scheduleHoverReentryReset(for seconds: TimeInterval = 1.2) {
        let work = DispatchWorkItem {
            hoverReentrySuppressed = false
            pendingHoverReentryReset = nil
        }
        pendingHoverReentryReset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func closeIslandAfterAction() {
        DiagnosticLogger.shared.info(
            "Island close after action queuedCount=\(notchCenter.queuedCount) hovering=\(effectiveHovering) state=\(String(describing: machine.state)) wasPeeking=\(wasPeekingOnEventArrival)"
        )
        // Event card and list card are decoupled:
        //   • If user was NOT peeking when the event arrived → suppress hover
        //     so the list card doesn't pop up after the event closes.
        //   • If user WAS peeking → don't suppress; `onChange(currentEvent→nil)`
        //     will call `machine.restoreHoverPeek()` and the list card comes
        //     back as it was before the event interrupted.
        if !wasPeekingOnEventArrival {
            suppressHoverReentry()
        }
        // Don't hide the state machine here. `notchCenter.dismiss(id:)` clears
        // `currentEvent`, which fires `onChange(currentEvent)` and drives the
        // appropriate transition (hide vs restore peek) in one place.
    }

    // MARK: - Compact content

    private func compactContent(for event: AttentionEvent) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(event.provider.badgeColor)
                .frame(width: 7, height: 7)
            Text(compactSummary(for: event))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if notchCenter.queuedCount > 0 {
                Text("+\(notchCenter.queuedCount)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
        }
    }

    private func compactSummary(for event: AttentionEvent) -> String {
        switch event.kind {
        case .permissionRequest(let tool, _, _, _):
            return String(format: LanguageManager.localizedString("notch.compact.permission"), tool)
        case .waitingInput:
            return String(format: LanguageManager.localizedString("notch.compact.waiting"), event.provider.displayName)
        case .taskDone:
            return LanguageManager.localizedString("notch.compact.done")
        case .taskFailed:
            return LanguageManager.localizedString("notch.compact.failed")
        case .sessionStart:
            return String(format: LanguageManager.localizedString("notch.compact.sessionStart"), event.provider.displayName)
        case .activityPulse, .sessionEnd:
            return event.provider.displayName
        }
    }

    @ViewBuilder
    private func expandedContent(for event: AttentionEvent) -> some View {
        let stableProjectPath = activeTracker.stableProjectPath(
            provider: event.provider,
            sessionId: event.sessionId,
            fallback: event.projectPath
        )
        switch event.kind {
        case .permissionRequest:
            PermissionRequestCard(
                event: event,
                projectPath: stableProjectPath,
                selectedAction: selectedEventAction,
                onDecide: { decision in
                    closeIslandAfterAction()
                    notchCenter.decide(id: event.id, decision: decision)
                },
                onAllowAlways: {
                    closeIslandAfterAction()
                    notchCenter.allowAlways(id: event.id)
                },
                onFocusTerminal: eventHasFocusHint(event) ? { focusTerminal(for: event) } : nil
            )
        case .waitingInput, .taskFailed, .sessionStart, .taskDone:
            // Unified card — WaitingInputCard handles all four kinds via its
            // `title` switch. taskDone uses the same layout as waitingInput
            // (title + activity + scrollable preview), so there's no reason
            // to keep a separate TaskDoneCard view.
            WaitingInputCard(
                notchCenter: notchCenter,
                event: event,
                projectPath: stableProjectPath,
                selectedAction: selectedEventAction,
                lastActivity: activeTracker.lastActivity(provider: event.provider, sessionId: event.sessionId),
                lastPreview: activeTracker.lastPreview(provider: event.provider, sessionId: event.sessionId),
                onFocusTerminal: eventHasFocusHint(event) ? { focusTerminal(for: event) } : nil
            ) {
                closeIslandAfterAction()
                notchCenter.dismiss(id: event.id)
            }
        case .activityPulse, .sessionEnd:
            EmptyView()
        }
    }

    private func eventHasFocusHint(_ event: AttentionEvent) -> Bool {
        activeTracker.focusContext(for: event).hasFocusHint
    }

    private var shouldCaptureKeyboard: Bool {
        if notchCenter.currentEvent != nil {
            return true
        }
        return idlePeekActive && (effectiveHovering || rawHovering || revealExpandedIsland)
    }

    private var visibleIdleSessions: [ActiveSession] {
        if idlePeekShowingAllSessions {
            return activeTracker.sessions
        }
        return Array(activeTracker.sessions.prefix(visibleIdleRows))
    }

    private var idlePeekHasToggle: Bool {
        activeTracker.totalCount > visibleIdleRows || idlePeekShowingAllSessions
    }

    private func availableEventActions(for event: AttentionEvent) -> [EventCardAction] {
        switch event.kind {
        case .permissionRequest:
            var actions: [EventCardAction] = []
            if eventHasFocusHint(event) {
                actions.append(.returnToTerminal)
            }
            if event.isActionableApproval {
                actions.append(contentsOf: [.deny, .allow, .allowAlways])
            } else {
                actions.append(.dismiss)
            }
            return actions
        case .waitingInput, .taskDone, .taskFailed, .sessionStart:
            var actions: [EventCardAction] = []
            if eventHasFocusHint(event) {
                actions.append(.returnToTerminal)
            }
            actions.append(.dismiss)
            return actions
        case .activityPulse, .sessionEnd:
            return []
        }
    }

    private func defaultEventAction(for event: AttentionEvent) -> EventCardAction? {
        switch event.kind {
        case .permissionRequest:
            return availableEventActions(for: event).contains(.allow) ? .allow : availableEventActions(for: event).first
        case .waitingInput, .taskDone, .taskFailed, .sessionStart:
            return availableEventActions(for: event).contains(.returnToTerminal) ? .returnToTerminal : .dismiss
        case .activityPulse, .sessionEnd:
            return nil
        }
    }

    private func syncKeyboardSelection() {
        if let event = notchCenter.currentEvent {
            let actions = availableEventActions(for: event)
            if !actions.contains(selectedEventAction ?? .dismiss) {
                selectedEventAction = defaultEventAction(for: event)
            }
        } else {
            selectedEventAction = nil
        }

        guard notchCenter.currentEvent == nil, idlePeekActive else {
            selectedIdleSessionID = nil
            idleToggleSelected = false
            onKeyboardCaptureChange(shouldCaptureKeyboard)
            return
        }

        guard idlePeekKeyboardMode else {
            selectedIdleSessionID = nil
            idleToggleSelected = false
            onKeyboardCaptureChange(shouldCaptureKeyboard)
            return
        }

        let sessions = visibleIdleSessions
        let hasToggle = idlePeekHasToggle

        if idleToggleSelected && !hasToggle {
            idleToggleSelected = false
        }

        if !idleToggleSelected {
            if let selectedIdleSessionID,
               sessions.contains(where: { $0.id == selectedIdleSessionID }) {
                // keep current selection
            } else if let first = sessions.first {
                self.selectedIdleSessionID = first.id
            } else {
                self.selectedIdleSessionID = nil
                idleToggleSelected = hasToggle
            }
        }

        onKeyboardCaptureChange(shouldCaptureKeyboard)
    }

    private func handleKeyboardAction(_ action: NotchKeyboardAction) {
        guard NotchPreferences.keyboardControlsEnabled else { return }
        if let event = notchCenter.currentEvent {
            handleEventKeyboardAction(action, event: event)
            return
        }

        guard idlePeekActive else { return }
        handleIdlePeekKeyboardAction(action)
    }

    private func handleIslandCommand(_ command: NotchIslandCommand) {
        switch command {
        case .toggleIdlePeekFromShortcut:
            if notchCenter.currentEvent != nil || closingEvent != nil {
                return
            }
            if idlePeekActive || closingIdlePeek {
                beginIdlePeekClose(force: true)
            } else {
                openIdlePeekFromShortcut()
            }
        }
    }

    private func openIdlePeekFromShortcut() {
        pendingIdlePeekOpen?.cancel()
        pendingIdlePeekOpen = nil
        pendingIdlePeekCloseStart?.cancel()
        pendingIdlePeekCloseStart = nil
        pendingIdlePeekClose?.cancel()
        pendingIdlePeekClose = nil
        pendingHoverLeave?.cancel()
        pendingHoverLeave = nil
        pendingInternalHoverGuardCheck?.cancel()
        pendingInternalHoverGuardCheck = nil
        pendingNearbyHoverGuardCheck?.cancel()
        pendingNearbyHoverGuardCheck = nil
        internalInteractionHoverGuardSize = nil
        hoverReentrySuppressed = false
        closingIdlePeek = false
        isClosingReveal = false
        idlePeekKeyboardMode = true
        idlePeekActive = true

        if !effectiveHovering {
            effectiveHovering = true
            deliverHover(true)
        }

        syncKeyboardSelection()
        schedulePanelExpansion {}
    }

    private func handleEventKeyboardAction(_ action: NotchKeyboardAction, event: AttentionEvent) {
        let actions = availableEventActions(for: event)
        guard !actions.isEmpty else { return }

        let current = selectedEventAction ?? defaultEventAction(for: event) ?? actions[0]
        let currentIndex = actions.firstIndex(of: current) ?? 0

        switch action {
        case .left:
            selectedEventAction = actions[(currentIndex - 1 + actions.count) % actions.count]
        case .right:
            selectedEventAction = actions[(currentIndex + 1) % actions.count]
        case .confirm:
            executeEventAction(current, for: event)
        case .cancel:
            if actions.contains(.dismiss) {
                executeEventAction(.dismiss, for: event)
            }
        case .up, .down:
            break
        }
    }

    private func executeEventAction(_ action: EventCardAction, for event: AttentionEvent) {
        switch action {
        case .returnToTerminal:
            focusTerminal(for: event)
        case .dismiss:
            closeIslandAfterAction()
            notchCenter.dismiss(id: event.id)
        case .deny:
            closeIslandAfterAction()
            notchCenter.decide(id: event.id, decision: .deny)
        case .allow:
            closeIslandAfterAction()
            notchCenter.decide(id: event.id, decision: .allow)
        case .allowAlways:
            closeIslandAfterAction()
            notchCenter.allowAlways(id: event.id)
        }
    }

    private func handleIdlePeekKeyboardAction(_ action: NotchKeyboardAction) {
        let sessions = visibleIdleSessions
        let hasToggle = idlePeekHasToggle

        switch action {
        case .up:
            if !idlePeekKeyboardMode {
                idlePeekKeyboardMode = true
                syncKeyboardSelection()
                return
            }
            moveIdleSelection(delta: -1, sessions: sessions, hasToggle: hasToggle)
        case .down:
            if !idlePeekKeyboardMode {
                idlePeekKeyboardMode = true
                syncKeyboardSelection()
                return
            }
            moveIdleSelection(delta: 1, sessions: sessions, hasToggle: hasToggle)
        case .confirm:
            guard idlePeekKeyboardMode else { return }
            if idleToggleSelected, hasToggle {
                holdHoverForInternalInteraction()
                idlePeekShowingAllSessions.toggle()
                syncKeyboardSelection()
            } else if let selectedIdleSessionID,
                      let session = sessions.first(where: { $0.id == selectedIdleSessionID }) {
                focusTerminal(for: session)
            }
        case .cancel:
            beginIdlePeekClose(force: true)
        case .left, .right:
            break
        }
    }

    private func moveIdleSelection(delta: Int, sessions: [ActiveSession], hasToggle: Bool) {
        var entries = sessions.map(\.id)
        if hasToggle {
            entries.append("__toggle__")
        }
        guard !entries.isEmpty else { return }

        let currentKey: String
        if idleToggleSelected, hasToggle {
            currentKey = "__toggle__"
        } else if let selectedIdleSessionID, entries.contains(selectedIdleSessionID) {
            currentKey = selectedIdleSessionID
        } else {
            currentKey = entries[0]
        }

        let currentIndex = entries.firstIndex(of: currentKey) ?? 0
        let nextIndex = (currentIndex + delta + entries.count) % entries.count
        let nextKey = entries[nextIndex]
        idleToggleSelected = nextKey == "__toggle__"
        selectedIdleSessionID = idleToggleSelected ? nil : nextKey
    }
}

// MARK: - IdlePeekCard — moved to Cards/IdlePeekCard.swift

// MARK: - ActiveSessionRow — moved to Cards/ActiveSessionRow.swift
