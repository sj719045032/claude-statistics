import Foundation
import SwiftUI

final class ZaiAPIService {
    static let shared = ZaiAPIService()

    private let baseURL = "https://api.z.ai/api/monitor/usage"
    private let cacheFileName = "zai-usage-cache.json"

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private let queryTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {}

    // MARK: - Fetch Quota Limits

    func fetchQuotaLimits() async throws -> [ZaiQuotaLimitDisplay] {
        guard let apiKey = await ZaiCredentialService.shared.getAPIKeyAsync() else {
            throw ZaiError.noAPIKey
        }

        guard let url = URL(string: "\(baseURL)/quota/limit") else {
            throw ZaiError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZaiError.httpError(statusCode: -1)
        }

        guard httpResponse.statusCode == 200 else {
            throw ZaiError.httpError(statusCode: httpResponse.statusCode)
        }

        let quotaResponse: ZaiQuotaResponse
        do {
            quotaResponse = try JSONDecoder().decode(ZaiQuotaResponse.self, from: data)
        } catch {
            throw ZaiError.decodingFailed(detail: error.localizedDescription)
        }

        let displays = processLimits(quotaResponse.data.limits)
        return displays
    }

    // MARK: - Fetch Model Usage

    func fetchModelUsage(range: ZaiTimeRange) async throws -> ZaiModelUsageDisplay {
        guard let apiKey = await ZaiCredentialService.shared.getAPIKeyAsync() else {
            throw ZaiError.noAPIKey
        }

        let (startTime, endTime) = timeRange(for: range)

        var components = URLComponents(string: "\(baseURL)/model-usage")
        components?.queryItems = [
            URLQueryItem(name: "startTime", value: queryTimeFormatter.string(from: startTime)),
            URLQueryItem(name: "endTime", value: queryTimeFormatter.string(from: endTime))
        ]

        guard let url = components?.url else {
            throw ZaiError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZaiError.httpError(statusCode: -1)
        }

        guard httpResponse.statusCode == 200 else {
            throw ZaiError.httpError(statusCode: httpResponse.statusCode)
        }

        let usageResponse: ZaiModelUsageResponse
        do {
            usageResponse = try JSONDecoder().decode(ZaiModelUsageResponse.self, from: data)
        } catch {
            throw ZaiError.decodingFailed(detail: error.localizedDescription)
        }

        return processModelUsage(usageResponse.data)
    }

    // MARK: - Process Limits

    private func processLimits(_ limits: [ZaiLimit]) -> [ZaiQuotaLimitDisplay] {
        var displays: [ZaiQuotaLimitDisplay] = []

        for limit in limits {
            let kind = ZaiQuotaKind(type: limit.type, unit: limit.unit)

            let resetDate = limit.nextResetTime.map {
                Date(timeIntervalSince1970: TimeInterval($0) / 1000.0)
            }

            let timeUntilReset: TimeInterval?
            if let date = resetDate {
                let interval = date.timeIntervalSinceNow
                timeUntilReset = interval > 0 ? interval : nil
            } else {
                timeUntilReset = nil
            }

            displays.append(ZaiQuotaLimitDisplay(
                kind: kind,
                percentage: limit.percentage,
                nextResetDate: resetDate,
                timeUntilReset: timeUntilReset,
                usageDetails: limit.usageDetails,
                usage: limit.usage,
                remaining: limit.remaining
            ))
        }

        return displays
    }

    // MARK: - Process Model Usage

    private func processModelUsage(_ data: ZaiModelUsageData) -> ZaiModelUsageDisplay {
        var points: [ZaiChartPoint] = []

        for i in 0..<data.xTime.count {
            guard let timeStr = data.xTime[i],
                  let time = timeFormatter.date(from: timeStr) else { continue }

            let calls = data.modelCallCount[i] ?? 0
            let tokens = data.tokensUsage[i] ?? 0

            // Skip null entries (both arrays had null)
            if data.modelCallCount[i] == nil && data.tokensUsage[i] == nil { continue }

            points.append(ZaiChartPoint(time: time, calls: calls, tokens: tokens))
        }

        return ZaiModelUsageDisplay(
            points: points,
            totalCalls: data.totalUsage.totalModelCallCount,
            totalTokens: data.totalUsage.totalTokensUsage
        )
    }

    // MARK: - Time Range Helpers

    private func timeRange(for range: ZaiTimeRange) -> (start: Date, end: Date) {
        let window = range.requestWindow()
        return (start: window.start, end: window.end)
    }

    // MARK: - Cache

    func loadFromCache() -> (quota: [ZaiQuotaLimitDisplay], modelUsage: ZaiModelUsageDisplay?, fetchedAt: Date)? {
        guard let data = FileManager.default.contents(atPath: cacheFilePath()) else { return nil }

        do {
            let cache = try JSONDecoder().decode(ZaiUsageCacheFile.self, from: data)
            guard let timestamp = TimeInterval(cache.fetchedAt) else { return nil }

            let quota = cache.quotaLimits.map { entry -> ZaiQuotaLimitDisplay in
                let resetDate = entry.nextResetTime.map {
                    Date(timeIntervalSince1970: TimeInterval($0) / 1000.0)
                }
                let timeUntilReset: TimeInterval? = resetDate.flatMap { date in
                    let interval = date.timeIntervalSinceNow
                    return interval > 0 ? interval : nil
                }
                let kind = entry.kind ?? ZaiQuotaKind(cacheKey: entry.titleKey) ?? .weekly

                return ZaiQuotaLimitDisplay(
                    kind: kind,
                    percentage: entry.percentage,
                    nextResetDate: resetDate,
                    timeUntilReset: timeUntilReset,
                    usageDetails: entry.usageDetails,
                    usage: entry.usage,
                    remaining: entry.remaining
                )
            }

            let modelUsage = cache.modelUsage.map { mu -> ZaiModelUsageDisplay in
                let points = mu.points.map { p in
                    ZaiChartPoint(time: Date(timeIntervalSince1970: p.time), calls: p.calls, tokens: p.tokens)
                }
                return ZaiModelUsageDisplay(points: points, totalCalls: mu.totalCalls, totalTokens: mu.totalTokens)
            }

            return (quota: quota, modelUsage: modelUsage, fetchedAt: Date(timeIntervalSince1970: timestamp))
        } catch {
            return nil
        }
    }

    func saveToCache(quota: [ZaiQuotaLimitDisplay], modelUsage: ZaiModelUsageDisplay?) {
        let quotaEntries = quota.map { limit -> ZaiQuotaLimitCacheEntry in
            return ZaiQuotaLimitCacheEntry(
                kind: limit.kind,
                titleKey: limit.kind.titleKey,
                percentage: limit.percentage,
                nextResetTime: limit.nextResetDate.map { Int64($0.timeIntervalSince1970 * 1000) },
                usageDetails: limit.usageDetails,
                usage: limit.usage,
                remaining: limit.remaining
            )
        }

        let modelUsageCache = modelUsage.map { mu -> ZaiModelUsageCacheData in
            let points = mu.points.map { p in
                ZaiChartPointCacheEntry(time: p.time.timeIntervalSince1970, calls: p.calls, tokens: p.tokens)
            }
            return ZaiModelUsageCacheData(points: points, totalCalls: mu.totalCalls, totalTokens: mu.totalTokens)
        }

        let cache = ZaiUsageCacheFile(
            fetchedAt: String(Int(Date().timeIntervalSince1970)),
            quotaLimits: quotaEntries,
            modelUsage: modelUsageCache
        )

        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: URL(fileURLWithPath: cacheFilePath()))
        } catch {
            // Silently fail
        }
    }

    private func cacheFilePath() -> String {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-statistics")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        return (dir as NSString).appendingPathComponent(cacheFileName)
    }
}
