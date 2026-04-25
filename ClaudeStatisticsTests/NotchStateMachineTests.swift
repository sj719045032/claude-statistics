import XCTest

@testable import Claude_Statistics

@MainActor
final class NotchStateMachineTests: XCTestCase {

    // MARK: - Initial state

    func test_initialState_isIdle() {
        let sm = NotchStateMachine()
        XCTAssertEqual(sm.state, .idle)
        XCTAssertFalse(sm.expandedViaHover)
    }

    // MARK: - show / expand / collapse / hide

    func test_show_compact_byDefault() {
        let sm = NotchStateMachine()
        sm.show()
        XCTAssertEqual(sm.state, .compact)
        XCTAssertFalse(sm.expandedViaHover)
    }

    func test_show_expanded() {
        let sm = NotchStateMachine()
        sm.show(expanded: true)
        XCTAssertEqual(sm.state, .expanded)
        XCTAssertFalse(sm.expandedViaHover)
    }

    func test_expand_fromIdle() {
        let sm = NotchStateMachine()
        sm.expand()
        XCTAssertEqual(sm.state, .expanded)
        XCTAssertFalse(sm.expandedViaHover)
    }

    func test_expand_clearsHoverFlag() {
        // If the user is hovering (expandedViaHover=true) when an event
        // arrives and calls expand(), the state must transition to a
        // proper event-driven expansion (expandedViaHover=false) so a
        // mouse-leave doesn't yank the event card away.
        let sm = NotchStateMachine()
        sm.show()
        sm.handleHover(true)  // hover-expanded
        XCTAssertTrue(sm.expandedViaHover)
        sm.expand()
        XCTAssertEqual(sm.state, .expanded)
        XCTAssertFalse(sm.expandedViaHover, "expand() must clear hover flag so card survives mouse-leave")
    }

    func test_collapse_compactState() {
        let sm = NotchStateMachine()
        sm.expand()
        sm.collapse()
        XCTAssertEqual(sm.state, .compact)
        XCTAssertFalse(sm.expandedViaHover)
    }

    func test_hide_returnsToIdle() {
        let sm = NotchStateMachine()
        sm.expand()
        sm.hide()
        XCTAssertEqual(sm.state, .idle)
        XCTAssertFalse(sm.expandedViaHover)
    }

    // MARK: - Hover behaviour (the load-bearing expandedViaHover invariant)

    func test_hover_compactToHoverExpanded() {
        let sm = NotchStateMachine()
        sm.show()  // compact
        sm.handleHover(true)
        XCTAssertEqual(sm.state, .expanded)
        XCTAssertTrue(sm.expandedViaHover, "hover-driven expansion must mark expandedViaHover=true")
    }

    func test_hover_leavingHoverExpansion_collapsesToCompact() {
        let sm = NotchStateMachine()
        sm.show()
        sm.handleHover(true)
        sm.handleHover(false)
        XCTAssertEqual(sm.state, .compact, "leaving hover-expanded must drop back to compact")
        XCTAssertFalse(sm.expandedViaHover)
    }

    func test_hover_leavingEventExpansion_staysExpanded() {
        // The key invariant: event-driven expansion (expandedViaHover=false)
        // must NOT collapse on mouse-leave. Otherwise a notification
        // disappears the moment the user moves their pointer away.
        let sm = NotchStateMachine()
        sm.expand()  // event-driven; expandedViaHover stays false
        sm.handleHover(true)   // user hovers in
        sm.handleHover(false)  // user leaves
        XCTAssertEqual(sm.state, .expanded, "event-driven expansion must survive mouse-leave")
        XCTAssertFalse(sm.expandedViaHover)
    }

    func test_hover_intoEventExpansion_doesNotFlipHoverFlag() {
        // Event driven; expandedViaHover=false. Hovering in shouldn't
        // change anything (we're already expanded; nothing to upgrade).
        let sm = NotchStateMachine()
        sm.expand()
        sm.handleHover(true)
        XCTAssertEqual(sm.state, .expanded)
        XCTAssertFalse(sm.expandedViaHover, "hover into event-expanded must not flip the hover flag")
    }

    func test_hover_fromIdle_doesNotChangeState() {
        let sm = NotchStateMachine()
        // idle → hover should be a no-op (no compact yet to upgrade).
        sm.handleHover(true)
        XCTAssertEqual(sm.state, .idle)
        XCTAssertFalse(sm.expandedViaHover)
    }

    // MARK: - restoreHoverPeek

    func test_restoreHoverPeek_setsExpandedAndHoverFlag() {
        let sm = NotchStateMachine()
        sm.restoreHoverPeek()
        XCTAssertEqual(sm.state, .expanded)
        XCTAssertTrue(sm.expandedViaHover)
    }

    func test_restoreHoverPeek_thenLeaveCollapsesProperly() {
        // Simulates: event card was showing, user hovered list, event
        // card dismissed → restoreHoverPeek brings list back. When user
        // then leaves, it should collapse like a normal hover peek.
        let sm = NotchStateMachine()
        sm.restoreHoverPeek()
        sm.handleHover(false)
        XCTAssertEqual(sm.state, .compact)
        XCTAssertFalse(sm.expandedViaHover)
    }
}
