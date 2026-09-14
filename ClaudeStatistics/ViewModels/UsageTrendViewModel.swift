import Combine
import Foundation
import ClaudeStatisticsKit

/// The request contains stable values only. SwiftUI redraws cannot introduce
/// new cache keys; a visible view advances its clock explicitly instead.
struct UsageTrendRequest: Hashable, Sendable {
    enum ModelFilter: Hashable, Sendable {
        case all
        case matching(String, excluding: String? = nil)

        func includes(_ model: String) -> Bool {
            switch self {
            case .all: return true
            case let .matching(term, excluded):
                let lower = model.lowercased()
                return lower.contains(term.lowercased()) &&
                    !(excluded.map { lower.contains($0.lowercased()) } ?? false)
            }
        }
    }

    let source: ObjectIdentifier
    let version: UInt64
    let windowStart: Date
    let windowEnd: Date
    let dataEnd: Date
    let granularity: TrendGranularity
    let modelFilter: ModelFilter
}

@MainActor
final class UsageTrendViewModel: ObservableObject {
    struct Input: Sendable {
        let request: UsageTrendRequest
        let stats: [String: SessionStats]
        let pricing: ModelPricing.Snapshot
    }

    struct Result: Sendable {
        let request: UsageTrendRequest
        let dataPoints: [TrendDataPoint]
        let modelBreakdown: [ModelUsage]

        var estimatedBytes: Int {
            dataPoints.count * 64 + modelBreakdown.reduce(0) { $0 + 256 + $1.model.utf8.count }
        }
    }

    @Published private(set) var result: Result?
    private let compute: @Sendable (Input) async throws -> Result
    private let cacheLimit: Int
    private let byteLimit: Int
    private var cache: [UsageTrendRequest: Result] = [:]
    private var recency: [UsageTrendRequest] = []
    private var requested: UsageTrendRequest?
    private var cacheBytes = 0
    var cachedCount: Int { cache.count }

    private lazy var worker = LatestSnapshotWorker<Input, Result>(
        compute: compute,
        publish: { [weak self] value in self?.publish(value) }
    )

    init(cacheLimit: Int = 8, byteLimit: Int = 2 * 1024 * 1024,
         compute: @escaping @Sendable (Input) async throws -> Result = { try await UsageTrendViewModel.calculate($0) }) {
        self.cacheLimit = max(1, cacheLimit)
        self.byteLimit = max(1, byteLimit)
        self.compute = compute
    }

    func request(_ input: Input) {
        let key = input.request
        guard requested != key else { return }
        if requested?.source != key.source || requested?.version != key.version {
            clearCache()
        }
        requested = key
        result = nil
        if let cached = cache[key] {
            worker.cancel()
            touch(key)
            result = cached
        } else {
            worker.submit(input)
        }
    }

    func stop() {
        worker.cancel()
        requested = nil
        result = nil
        clearCache()
    }

    private func publish(_ value: Result) {
        guard requested == value.request else { return }
        if value.estimatedBytes <= byteLimit {
            cache[value.request] = value
            cacheBytes += value.estimatedBytes
            touch(value.request)
            while cache.count > cacheLimit || cacheBytes > byteLimit {
                let oldest = recency.removeFirst()
                if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= removed.estimatedBytes }
            }
        }
        result = value
    }

    private func touch(_ key: UsageTrendRequest) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func clearCache() {
        cache.removeAll()
        recency.removeAll()
        cacheBytes = 0
    }

    nonisolated static func calculate(_ input: Input) async throws -> Result {
        try await BackgroundWorkScheduler.shared.run(priority: .interactive) {
            try Task.checkCancellation()
            let span = PerformanceTracer.begin("UsageTrendViewModel.calculate")
            defer { PerformanceTracer.end("UsageTrendViewModel.calculate", span) }
            let query = input.request
            let filter: ((String) -> Bool)? = query.modelFilter == .all ? nil : query.modelFilter.includes
            let data = SessionTrendAggregator.windowTrendData(
                parsedStats: input.stats, from: query.windowStart, to: query.dataEnd,
                granularity: query.granularity, cumulative: true, modelFilter: filter,
                pricing: input.pricing, maxPoints: 1_200)
            try Task.checkCancellation()
            let models = SessionTrendAggregator.windowModelBreakdown(
                parsedStats: input.stats, from: query.windowStart, to: query.dataEnd,
                modelFilter: filter, pricing: input.pricing)
            try Task.checkCancellation()
            return Result(request: query, dataPoints: data, modelBreakdown: models)
        }
    }
}
