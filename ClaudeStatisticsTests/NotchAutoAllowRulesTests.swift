import XCTest

@testable import Claude_Statistics

final class NotchAutoAllowRulesTests: XCTestCase {
    func test_emptyAtStart() {
        let rules = NotchAutoAllowRules()
        XCTAssertFalse(rules.contains(provider: .claude, sessionId: "s1", toolName: "Bash"))
    }

    func test_insertThenContains() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "s1", toolName: "Bash")
        XCTAssertTrue(rules.contains(provider: .claude, sessionId: "s1", toolName: "Bash"))
    }

    func test_distinctSessionsTracked() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "s1", toolName: "Bash")
        XCTAssertFalse(rules.contains(provider: .claude, sessionId: "s2", toolName: "Bash"))
    }

    func test_distinctToolsTracked() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "s1", toolName: "Bash")
        XCTAssertFalse(rules.contains(provider: .claude, sessionId: "s1", toolName: "Read"))
    }

    func test_distinctProvidersTracked() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "s1", toolName: "Bash")
        XCTAssertFalse(rules.contains(provider: .codex, sessionId: "s1", toolName: "Bash"))
    }

    func test_emptySessionIdRejectsInsert() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "", toolName: "Bash")
        XCTAssertFalse(rules.contains(provider: .claude, sessionId: "", toolName: "Bash"))
    }

    func test_nilToolNameRejectsInsert() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "s1", toolName: nil)
        XCTAssertFalse(rules.contains(provider: .claude, sessionId: "s1", toolName: nil))
    }

    func test_emptyToolNameRejectsInsert() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "s1", toolName: "")
        XCTAssertFalse(rules.contains(provider: .claude, sessionId: "s1", toolName: ""))
    }

    func test_clearRemovesAllRulesInSession() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "s1", toolName: "Bash")
        rules.insert(provider: .claude, sessionId: "s1", toolName: "Read")
        rules.clear(provider: .claude, sessionId: "s1")
        XCTAssertFalse(rules.contains(provider: .claude, sessionId: "s1", toolName: "Bash"))
        XCTAssertFalse(rules.contains(provider: .claude, sessionId: "s1", toolName: "Read"))
    }

    func test_clearKeepsOtherSessions() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "s1", toolName: "Bash")
        rules.insert(provider: .claude, sessionId: "s2", toolName: "Bash")
        rules.clear(provider: .claude, sessionId: "s1")
        XCTAssertFalse(rules.contains(provider: .claude, sessionId: "s1", toolName: "Bash"))
        XCTAssertTrue(rules.contains(provider: .claude, sessionId: "s2", toolName: "Bash"))
    }

    func test_clearKeepsOtherProviders() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "s1", toolName: "Bash")
        rules.insert(provider: .codex, sessionId: "s1", toolName: "Bash")
        rules.clear(provider: .claude, sessionId: "s1")
        XCTAssertFalse(rules.contains(provider: .claude, sessionId: "s1", toolName: "Bash"))
        XCTAssertTrue(rules.contains(provider: .codex, sessionId: "s1", toolName: "Bash"))
    }

    func test_clearWithEmptySessionIdIsNoOp() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "s1", toolName: "Bash")
        rules.clear(provider: .claude, sessionId: "")
        XCTAssertTrue(rules.contains(provider: .claude, sessionId: "s1", toolName: "Bash"))
    }

    func test_doubleInsertIsIdempotent() {
        var rules = NotchAutoAllowRules()
        rules.insert(provider: .claude, sessionId: "s1", toolName: "Bash")
        rules.insert(provider: .claude, sessionId: "s1", toolName: "Bash")
        XCTAssertTrue(rules.contains(provider: .claude, sessionId: "s1", toolName: "Bash"))
    }
}
