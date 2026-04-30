import XCTest

@testable import Claude_Statistics

@MainActor
final class UsageVMRegistryTests: XCTestCase {

    // MARK: - viewModel(for:currentProvider:) routing

    func test_currentProviderKind_returnsPrimary() {
        let registry = UsageVMRegistry(lookupStore: { _ in nil })
        // No secondaries booted yet — primary is the only VM that exists.
        let resolved = registry.viewModel(for: .claude, currentProvider: .claude)
        XCTAssertTrue(resolved === registry.primary, "current provider must return the primary VM")
    }

    func test_nonCurrentProviderKind_returnsNilWhenNoSecondaryBooted() {
        let registry = UsageVMRegistry(lookupStore: { _ in nil })
        let resolved = registry.viewModel(for: .codex, currentProvider: .claude)
        XCTAssertNil(resolved, "non-current provider with no secondary returns nil")
    }

    func test_nonCurrentProviderKind_returnsBootedSecondary() {
        let registry = UsageVMRegistry(lookupStore: { _ in nil })
        registry.bootSecondary(for: .codex)
        let resolved = registry.viewModel(for: .codex, currentProvider: .claude)
        XCTAssertNotNil(resolved, "secondary VM must be returned after bootSecondary")
        XCTAssertFalse(resolved === registry.primary, "secondary must be a distinct VM from primary")
    }

    // MARK: - swap on provider switch

    func test_swap_promotesIncomingAndDemotesOutgoing() {
        // lookupStore must report the outgoing kind has a store, otherwise
        // swap skips re-creating its secondary VM.
        let store = SessionDataStore(kind: .claude)
        let registry = UsageVMRegistry(lookupStore: { kind in kind == .claude ? store : nil })

        // Start: codex is in the secondary pool, claude is current.
        registry.bootSecondary(for: .codex)
        XCTAssertNotNil(registry.secondaries[.codex])

        // Switch claude → codex: codex's secondary should be removed
        // (it's served by primary now), and a new claude secondary spun
        // up so the menu-bar strip keeps refreshing it.
        registry.swap(from: .claude, to: .codex)
        XCTAssertNil(registry.secondaries[.codex], "incoming kind is promoted out of secondary pool")
        XCTAssertNotNil(registry.secondaries[.claude], "outgoing kind is demoted into secondary pool")
    }

    func test_swap_skipsDemotedSecondaryWhenStoreMissing() {
        // No store for any kind → swap should not create a secondary for
        // the outgoing kind (no store means we couldn't drive it anyway).
        let registry = UsageVMRegistry(lookupStore: { _ in nil })
        registry.bootSecondary(for: .codex)

        registry.swap(from: .claude, to: .codex)
        XCTAssertNil(registry.secondaries[.codex])
        XCTAssertNil(registry.secondaries[.claude], "no store for outgoing kind → no secondary")
    }
}
