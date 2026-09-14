import XCTest
import ClaudeStatisticsKit
@testable import Claude_Statistics

@MainActor
final class UsageRefreshTests: XCTestCase {
    private actor Source: ProviderUsageSource {
        var calls = 0
        var credentialCalls = 0
        var pending: [CheckedContinuation<ProviderUsageSnapshot, Error>] = []
        var error: UsageError?
        var shouldSuspend = false
        var unauthorizedOnce = false
        let percent: Double

        init(percent: Double = 42) { self.percent = percent }
        nonisolated func loadCachedSnapshot() -> ProviderUsageSnapshot? { nil }
        func setError(_ value: UsageError?) { error = value }
        func suspend() { shouldSuspend = true }
        func requireAuthentication() { unauthorizedOnce = true }
        func refreshSnapshot() async throws -> ProviderUsageSnapshot {
            calls += 1
            if unauthorizedOnce { unauthorizedOnce = false; throw UsageError.unauthorized }
            if shouldSuspend { return try await withCheckedThrowingContinuation { pending.append($0) } }
            if let error { throw error }
            return snapshot()
        }
        func refreshCredentials() async -> Bool { credentialCalls += 1; return true }
        func finish(error: UsageError? = nil) {
            let waiters = pending
            pending.removeAll()
            shouldSuspend = false
            for waiter in waiters {
                if let error { waiter.resume(throwing: error) }
                else { waiter.resume(returning: snapshot()) }
            }
        }
        private func snapshot() -> ProviderUsageSnapshot {
            .init(data: .init(fiveHour: .init(utilization: percent)), fetchedAt: Date(timeIntervalSince1970: 1234))
        }
    }

    private func waitForCalls(_ count: Int, source: Source) async {
        for _ in 0..<1000 {
            if await source.calls >= count { return }
            await Task.yield()
        }
        XCTFail("Expected request did not start")
    }

    func testSimultaneousManualAndAutomaticRefreshShareRequestAndPublishBeforeReturn() async {
        let source = Source()
        await source.suspend()
        let vm = UsageViewModel()
        vm.configure(source: source, usagePresentation: .standard)
        let first = Task { await vm.refresh() }
        await waitForCalls(1, source: source)
        let second = Task { await vm.forceRefresh(); XCTAssertEqual(vm.fiveHourPercent, 42); XCTAssertFalse(vm.isLoading) }
        for _ in 0..<20 { await Task.yield() }
        let calls = await source.calls
        XCTAssertEqual(calls, 1)
        await source.finish()
        await first.value
        await second.value
        XCTAssertEqual(vm.fiveHourPercent, 42)
    }

    func testSourceReplacementRejectsNonCooperativeOldResult() async {
        let old = Source(percent: 99)
        await old.suspend()
        let vm = UsageViewModel()
        vm.configure(source: old, usagePresentation: .standard)
        let first = Task { await vm.refresh() }
        await waitForCalls(1, source: old)
        let current = Source(percent: 20)
        vm.configure(source: current, usagePresentation: .standard)
        await vm.refresh()
        XCTAssertEqual(vm.fiveHourPercent, 20)
        await old.finish()
        await first.value
        XCTAssertEqual(vm.fiveHourPercent, 20)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testAutomaticBackoffAndManualRecovery() async {
        var time = Date(timeIntervalSince1970: 1000)
        let source = Source()
        await source.setError(.invalidResponse)
        let vm = UsageViewModel(now: { time })
        vm.configure(source: source, usagePresentation: .standard)
        await vm.refresh()
        await vm.refresh()
        await assertCalls(1, source: source)
        time.addTimeInterval(31)
        await vm.refresh()
        await assertCalls(2, source: source)
        time.addTimeInterval(31)
        await vm.refresh()
        await assertCalls(2, source: source)
        await source.setError(nil)
        await vm.forceRefresh()
        XCTAssertEqual(vm.fiveHourPercent, 42)
        XCTAssertNil(vm.errorMessage)
        await vm.refresh()
        await assertCalls(4, source: source)
    }

    func testRateLimitDeadlineAlsoProtectsManualRefresh() async {
        var time = Date(timeIntervalSince1970: 1000)
        let source = Source()
        await source.setError(.rateLimited(retryInSeconds: 120))
        let vm = UsageViewModel(now: { time })
        vm.configure(source: source, usagePresentation: .standard)
        await vm.refresh()
        XCTAssertNil(vm.errorMessage)
        await vm.forceRefresh()
        XCTAssertNotNil(vm.errorMessage)
        await assertCalls(1, source: source)
        time.addTimeInterval(121)
        await source.setError(nil)
        await vm.forceRefresh()
        await assertCalls(2, source: source)
        XCTAssertEqual(vm.fiveHourPercent, 42)
    }

    func testCredentialRetryRunsOnlyOnceForSharedRequest() async {
        let source = Source()
        await source.requireAuthentication()
        let vm = UsageViewModel()
        vm.configure(source: source, usagePresentation: .standard)
        await vm.refresh()
        let calls = await source.calls
        let credentialCalls = await source.credentialCalls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(credentialCalls, 1)
        XCTAssertEqual(vm.fiveHourPercent, 42)
    }

    private func assertCalls(_ expected: Int, source: Source, file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await source.calls
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}
