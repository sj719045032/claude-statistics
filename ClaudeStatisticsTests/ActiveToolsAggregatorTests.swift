import XCTest

@testable import Claude_Statistics

final class ActiveToolsAggregatorTests: XCTestCase {

    // MARK: - bucketKey

    func test_bucketKey_canonicalToolName() {
        XCTAssertEqual(ActiveToolsAggregator.bucketKey(toolName: "Read", detail: nil), "read")
        XCTAssertEqual(ActiveToolsAggregator.bucketKey(toolName: "Edit", detail: nil), "edit")
        XCTAssertEqual(ActiveToolsAggregator.bucketKey(toolName: "Grep", detail: nil), "grep")
    }

    func test_bucketKey_bashWithoutDetailReturnsBash() {
        XCTAssertEqual(ActiveToolsAggregator.bucketKey(toolName: "Bash", detail: nil), "bash")
    }

    func test_bucketKey_bashWithSearchingPrefixRoutesToGrep() {
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "Bash", detail: "Searching for fooPattern"),
            "grep"
        )
    }

    func test_bucketKey_bashWithFindingPrefixRoutesToFind() {
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "Bash", detail: "Finding files"),
            "find"
        )
    }

    func test_bucketKey_bashWithListingPrefixRoutesToLs() {
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "Bash", detail: "Listing /tmp"),
            "ls"
        )
    }

    func test_bucketKey_bashWithReadingPrefixRoutesToRead() {
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "Bash", detail: "Reading foo.txt"),
            "read"
        )
    }

    func test_bucketKey_bashWithFetchingPrefixRoutesToFetch() {
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "Bash", detail: "Fetching https://x"),
            "fetch"
        )
    }

    func test_bucketKey_bashWithUnknownDetailFallsBackToBash() {
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "Bash", detail: "Running ls"),
            "bash"
        )
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "Bash", detail: "make build"),
            "bash"
        )
    }

    func test_bucketKey_bashOutputBehavesLikeBash() {
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "BashOutput", detail: "Searching for x"),
            "grep"
        )
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "BashOutput", detail: nil),
            "bashoutput"
        )
    }

    func test_bucketKey_nonBashToolIgnoresDetail() {
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "Read", detail: "Searching foo"),
            "read",
            "non-bash detail should not trigger re-routing"
        )
    }

    func test_bucketKey_whitespaceTrimmed() {
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "Bash", detail: "   Searching for x   "),
            "grep"
        )
    }

    func test_bucketKey_prefixIsCaseSensitive() {
        XCTAssertEqual(
            ActiveToolsAggregator.bucketKey(toolName: "Bash", detail: "searching for x"),
            "bash",
            "lowercase 'searching' is not the canonical English prefix"
        )
    }

    // MARK: - phraseForBucket

    func test_phraseForBucket_countInterpolated() {
        let phrase = ActiveToolsAggregator.phraseForBucket(tool: "read", count: 3)
        XCTAssertTrue(phrase.contains("3"), "expected count 3 in phrase, got '\(phrase)'")
    }

    func test_phraseForBucket_distinctKeysProduceDistinctPhrases() {
        let reading = ActiveToolsAggregator.phraseForBucket(tool: "read", count: 1)
        let editing = ActiveToolsAggregator.phraseForBucket(tool: "edit", count: 1)
        let writing = ActiveToolsAggregator.phraseForBucket(tool: "write", count: 1)
        XCTAssertNotEqual(reading, editing)
        XCTAssertNotEqual(reading, writing)
        XCTAssertNotEqual(editing, writing)
    }

    func test_phraseForBucket_editAndMultiEditShareKey() {
        XCTAssertEqual(
            ActiveToolsAggregator.phraseForBucket(tool: "edit", count: 2),
            ActiveToolsAggregator.phraseForBucket(tool: "multiedit", count: 2)
        )
    }

    func test_phraseForBucket_bashAndBashOutputShareKey() {
        XCTAssertEqual(
            ActiveToolsAggregator.phraseForBucket(tool: "bash", count: 2),
            ActiveToolsAggregator.phraseForBucket(tool: "bashoutput", count: 2)
        )
    }

    func test_phraseForBucket_taskAndAgentShareKey() {
        XCTAssertEqual(
            ActiveToolsAggregator.phraseForBucket(tool: "task", count: 1),
            ActiveToolsAggregator.phraseForBucket(tool: "agent", count: 1)
        )
    }

    func test_phraseForBucket_websearchVariantsShareKey() {
        XCTAssertEqual(
            ActiveToolsAggregator.phraseForBucket(tool: "websearch", count: 1),
            ActiveToolsAggregator.phraseForBucket(tool: "web_search", count: 1)
        )
    }

    func test_phraseForBucket_fetchVariantsShareKey() {
        XCTAssertEqual(
            ActiveToolsAggregator.phraseForBucket(tool: "webfetch", count: 1),
            ActiveToolsAggregator.phraseForBucket(tool: "fetch", count: 1)
        )
    }

    func test_phraseForBucket_unknownToolFallsBackToGeneric() {
        let unknown = ActiveToolsAggregator.phraseForBucket(tool: "completely_made_up", count: 1)
        let generic = ActiveToolsAggregator.phraseForBucket(tool: "generic", count: 1)
        XCTAssertEqual(unknown, generic)
    }

    // MARK: - aggregateText

    func test_aggregateText_emptyReturnsNil() {
        XCTAssertNil(ActiveToolsAggregator.aggregateText(turnCounts: [:]))
    }

    func test_aggregateText_zeroOnlyReturnsNil() {
        XCTAssertNil(ActiveToolsAggregator.aggregateText(turnCounts: ["read": 0]))
    }

    func test_aggregateText_singleBucket() {
        let result = ActiveToolsAggregator.aggregateText(turnCounts: ["read": 1])
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("1"))
        XCTAssertFalse(result!.contains("·"), "single bucket should not have the · separator")
    }

    func test_aggregateText_multipleBucketsJoinedWithBullet() {
        let result = ActiveToolsAggregator.aggregateText(turnCounts: ["read": 1, "grep": 1])
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains(" · "), "expected · separator in '\(result!)'")
    }

    func test_aggregateText_sortedByCountDescending() {
        let result = ActiveToolsAggregator.aggregateText(turnCounts: ["read": 7, "grep": 2])
        XCTAssertNotNil(result)
        let readingPhrase = ActiveToolsAggregator.phraseForBucket(tool: "read", count: 7)
        let grepPhrase = ActiveToolsAggregator.phraseForBucket(tool: "grep", count: 2)
        let readingIndex = result!.range(of: readingPhrase)?.lowerBound
        let grepIndex = result!.range(of: grepPhrase)?.lowerBound
        XCTAssertNotNil(readingIndex)
        XCTAssertNotNil(grepIndex)
        XCTAssertLessThan(readingIndex!, grepIndex!, "higher count should come first")
    }

    func test_aggregateText_tieBreakerByKeyAscending() {
        let result = ActiveToolsAggregator.aggregateText(turnCounts: ["read": 1, "grep": 1])
        XCTAssertNotNil(result)
        let grepPhrase = ActiveToolsAggregator.phraseForBucket(tool: "grep", count: 1)
        let readPhrase = ActiveToolsAggregator.phraseForBucket(tool: "read", count: 1)
        let grepIndex = result!.range(of: grepPhrase)?.lowerBound
        let readIndex = result!.range(of: readPhrase)?.lowerBound
        XCTAssertLessThan(grepIndex!, readIndex!, "alphabetical key 'grep' < 'read' breaks ties")
    }

    func test_aggregateText_zeroBucketsAreFilteredOut() {
        // Defensive: if a bucket somehow lands at 0 alongside others, drop it
        // rather than rendering "Reading 0 files".
        let result = ActiveToolsAggregator.aggregateText(turnCounts: ["read": 3, "grep": 0])
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.contains(" · "), "zero bucket should not show: '\(result!)'")
        XCTAssertTrue(result!.contains("3"))
    }
}
