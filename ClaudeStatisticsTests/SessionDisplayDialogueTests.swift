import XCTest

@testable import Claude_Statistics

final class SessionDisplayDialogueTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        text: String,
        timestamp: Date? = nil,
        order: Int = 0,
        semanticKey: String? = nil
    ) -> SessionDisplayEntry {
        SessionDisplayEntry(
            text: text,
            symbol: "circle",
            semanticKey: semanticKey,
            timestamp: timestamp,
            order: order
        )
    }

    // MARK: - comparableDisplayKey

    func test_comparableDisplayKey_lowercases() {
        XCTAssertEqual(ProviderSessionDisplayFormatter.comparableDisplayKey("Hello World"), "hello world")
    }

    func test_comparableDisplayKey_trimsWhitespace() {
        XCTAssertEqual(ProviderSessionDisplayFormatter.comparableDisplayKey("  hello  "), "hello")
    }

    func test_comparableDisplayKey_stripsAsciiEllipsis() {
        XCTAssertEqual(ProviderSessionDisplayFormatter.comparableDisplayKey("thinking..."), "thinking")
    }

    func test_comparableDisplayKey_stripsUnicodeEllipsis() {
        XCTAssertEqual(ProviderSessionDisplayFormatter.comparableDisplayKey("thinking…"), "thinking")
    }

    func test_comparableDisplayKey_collapsesEllipsisVariantsToSameKey() {
        let ascii = ProviderSessionDisplayFormatter.comparableDisplayKey("Working...")
        let unicode = ProviderSessionDisplayFormatter.comparableDisplayKey("WORKING…")
        XCTAssertEqual(ascii, unicode)
    }

    func test_comparableDisplayKey_emptyHandled() {
        XCTAssertEqual(ProviderSessionDisplayFormatter.comparableDisplayKey(""), "")
        XCTAssertEqual(ProviderSessionDisplayFormatter.comparableDisplayKey("   "), "")
    }

    // MARK: - compareEntriesChronologically

    func test_chronological_earlierTimestampFirst() {
        let earlier = entry(text: "a", timestamp: now)
        let later = entry(text: "b", timestamp: now.addingTimeInterval(60))
        XCTAssertTrue(ProviderSessionDisplayFormatter.compareEntriesChronologically(earlier, later))
        XCTAssertFalse(ProviderSessionDisplayFormatter.compareEntriesChronologically(later, earlier))
    }

    func test_chronological_timedBeatsUntimed() {
        let timed = entry(text: "a", timestamp: now)
        let untimed = entry(text: "b", timestamp: nil)
        XCTAssertTrue(
            ProviderSessionDisplayFormatter.compareEntriesChronologically(timed, untimed),
            "entry with timestamp comes before one without"
        )
        XCTAssertFalse(ProviderSessionDisplayFormatter.compareEntriesChronologically(untimed, timed))
    }

    func test_chronological_bothNilFallsBackToOrder() {
        let first = entry(text: "a", timestamp: nil, order: 0)
        let second = entry(text: "b", timestamp: nil, order: 5)
        XCTAssertTrue(ProviderSessionDisplayFormatter.compareEntriesChronologically(first, second))
        XCTAssertFalse(ProviderSessionDisplayFormatter.compareEntriesChronologically(second, first))
    }

    func test_chronological_sameTimestampFallsBackToOrder() {
        let lhs = entry(text: "a", timestamp: now, order: 1)
        let rhs = entry(text: "b", timestamp: now, order: 9)
        XCTAssertTrue(ProviderSessionDisplayFormatter.compareEntriesChronologically(lhs, rhs))
    }

    func test_chronological_sortStableAcrossArray() {
        let items = [
            entry(text: "c", timestamp: now.addingTimeInterval(30), order: 2),
            entry(text: "a", timestamp: now, order: 0),
            entry(text: "b", timestamp: now.addingTimeInterval(15), order: 1),
        ]
        let sorted = items.sorted(by: ProviderSessionDisplayFormatter.compareEntriesChronologically)
        XCTAssertEqual(sorted.map(\.text), ["a", "b", "c"])
    }

    // MARK: - compareEntriesReverseChronologically

    func test_reverseChronological_laterTimestampFirst() {
        let earlier = entry(text: "a", timestamp: now)
        let later = entry(text: "b", timestamp: now.addingTimeInterval(60))
        XCTAssertTrue(ProviderSessionDisplayFormatter.compareEntriesReverseChronologically(later, earlier))
        XCTAssertFalse(ProviderSessionDisplayFormatter.compareEntriesReverseChronologically(earlier, later))
    }

    func test_reverseChronological_timedBeatsUntimed() {
        let timed = entry(text: "a", timestamp: now)
        let untimed = entry(text: "b", timestamp: nil)
        XCTAssertTrue(
            ProviderSessionDisplayFormatter.compareEntriesReverseChronologically(timed, untimed),
            "entries with timestamps still rank ahead of nil-timestamp"
        )
    }

    func test_reverseChronological_bothNilFallsBackToOrder() {
        let first = entry(text: "a", timestamp: nil, order: 0)
        let second = entry(text: "b", timestamp: nil, order: 5)
        XCTAssertTrue(
            ProviderSessionDisplayFormatter.compareEntriesReverseChronologically(first, second),
            "with no timestamps, lower order still wins (matches forward sort)"
        )
    }

    func test_reverseChronological_sortDescendingArray() {
        let items = [
            entry(text: "a", timestamp: now, order: 0),
            entry(text: "c", timestamp: now.addingTimeInterval(30), order: 2),
            entry(text: "b", timestamp: now.addingTimeInterval(15), order: 1),
        ]
        let sorted = items.sorted(by: ProviderSessionDisplayFormatter.compareEntriesReverseChronologically)
        XCTAssertEqual(sorted.map(\.text), ["c", "b", "a"])
    }

    func test_reverseChronological_sameTimestampFallsBackToOrder() {
        let lhs = entry(text: "a", timestamp: now, order: 1)
        let rhs = entry(text: "b", timestamp: now, order: 9)
        XCTAssertTrue(
            ProviderSessionDisplayFormatter.compareEntriesReverseChronologically(lhs, rhs),
            "tie on timestamp uses order ascending — same as forward"
        )
    }

    // MARK: - isDuplicateDisplayEntry

    func test_dedupe_sameSemanticKeyIsDuplicate() {
        let lhs = entry(text: "Read foo.swift", semanticKey: "Read:foo.swift")
        let rhs = entry(text: "Read foo.swift", semanticKey: "Read:foo.swift")
        XCTAssertTrue(ProviderSessionDisplayFormatter.isDuplicateDisplayEntry(lhs, rhs))
    }

    func test_dedupe_sameSemanticKeyDifferentTextStillDuplicate() {
        let lhs = entry(text: "Reading foo.swift", semanticKey: "Read:foo.swift")
        let rhs = entry(text: "Read foo.swift", semanticKey: "Read:foo.swift")
        XCTAssertTrue(
            ProviderSessionDisplayFormatter.isDuplicateDisplayEntry(lhs, rhs),
            "semantic key match overrides text differences"
        )
    }

    func test_dedupe_sameTextIsDuplicateRegardlessOfCase() {
        let lhs = entry(text: "Hello World")
        let rhs = entry(text: "HELLO WORLD")
        XCTAssertTrue(ProviderSessionDisplayFormatter.isDuplicateDisplayEntry(lhs, rhs))
    }

    func test_dedupe_ellipsisVariantsCollapse() {
        let lhs = entry(text: "Working...")
        let rhs = entry(text: "Working…")
        XCTAssertTrue(ProviderSessionDisplayFormatter.isDuplicateDisplayEntry(lhs, rhs))
    }

    func test_dedupe_distinctTextIsNotDuplicate() {
        let lhs = entry(text: "Reading foo")
        let rhs = entry(text: "Reading bar")
        XCTAssertFalse(ProviderSessionDisplayFormatter.isDuplicateDisplayEntry(lhs, rhs))
    }

    func test_dedupe_oneSemanticKeyOneNilUsesText() {
        let lhs = entry(text: "Read foo", semanticKey: "k")
        let rhs = entry(text: "Read foo", semanticKey: nil)
        XCTAssertTrue(
            ProviderSessionDisplayFormatter.isDuplicateDisplayEntry(lhs, rhs),
            "key on one side, nil on other → falls through to text comparison"
        )
    }

    func test_dedupe_differentSemanticKeysFallThroughToText() {
        let lhs = entry(text: "Reading foo", semanticKey: "k1")
        let rhs = entry(text: "Reading bar", semanticKey: "k2")
        XCTAssertFalse(
            ProviderSessionDisplayFormatter.isDuplicateDisplayEntry(lhs, rhs),
            "distinct semantic keys + distinct text → not duplicate"
        )
    }
}
