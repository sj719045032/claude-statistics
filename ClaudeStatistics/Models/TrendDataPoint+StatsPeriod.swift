import Foundation
import ClaudeStatisticsKit

/// `TrendDataPoint` and `TrendGranularity` live in `ClaudeStatisticsKit`
/// (plugins emit these from their transcript parsers). The
/// `StatsPeriod`-bound extension stays here because `StatsPeriod` is a
/// host-internal aggregation concept.
extension StatsPeriod {
    /// The trend chart granularity for this period type.
    var trendGranularity: TrendGranularity {
        switch self {
        case .all:     return .day
        case .daily:   return .hour
        case .weekly:  return .day
        case .monthly: return .day
        }
    }
}
