import Foundation

struct UsageHistorySample {
    let ts: Date
    let fhPct: Double
    let fhReset: Date
    let sdPct: Double
    let sdReset: Date
}

final class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    private let filePath: String

    private init() {
        filePath = (AppRuntimePaths.rootDirectory as NSString).appendingPathComponent("usage-history.jsonl")
    }

    func load() -> [UsageHistorySample] {
        guard let data = FileManager.default.contents(atPath: filePath),
              let text = String(data: data, encoding: .utf8) else { return [] }

        return text.components(separatedBy: "\n").compactMap { line in
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let ts = (json["ts"] as? TimeInterval),
                  let fh = (json["fh"] as? Double),
                  let fhR = (json["fh_r"] as? TimeInterval),
                  let sd = (json["sd"] as? Double),
                  let sdR = (json["sd_r"] as? TimeInterval)
            else { return nil }

            return UsageHistorySample(
                ts: Date(timeIntervalSince1970: ts),
                fhPct: fh,
                fhReset: Date(timeIntervalSince1970: fhR),
                sdPct: sd,
                sdReset: Date(timeIntervalSince1970: sdR)
            )
        }
    }

    /// Returns average %/second consumption rate from completed 7-day windows in the past 14 days.
    /// Each window's consumption = max(sd%) - min(sd%) within that window.
    /// Returns nil if no completed windows exist in history.
    func sevenDayAverageRate(lookbackDays: Int = 14) -> Double? {
        let now = Date()
        let cutoff = now.addingTimeInterval(-TimeInterval(lookbackDays) * 86400)

        // Group samples by window key (sd_r as unix timestamp)
        var windows: [TimeInterval: [UsageHistorySample]] = [:]
        for sample in load() where sample.ts >= cutoff {
            windows[sample.sdReset.timeIntervalSince1970, default: []].append(sample)
        }

        var totalConsumption = 0.0
        var completedCount = 0

        for (resetTs, samples) in windows {
            let resetDate = Date(timeIntervalSince1970: resetTs)
            guard resetDate < now else { continue }  // skip current window
            let lo = samples.map(\.sdPct).min() ?? 0
            let hi = samples.map(\.sdPct).max() ?? 0
            let consumption = hi - lo
            guard consumption > 0 else { continue }
            totalConsumption += consumption
            completedCount += 1
        }

        guard completedCount > 0 else { return nil }

        let avgPer7Days = totalConsumption / Double(completedCount)
        return (avgPer7Days / 7.0) / 86400  // %/second
    }
}
