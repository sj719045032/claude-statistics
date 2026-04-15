import Foundation

struct TrendDataPoint: Identifiable {
    let id = UUID()
    let time: Date
    let tokens: Int       // input + output + cacheCreation + cacheRead
    let cost: Double      // USD
}

enum TrendGranularity: String, CaseIterable {
    case fiveMinute, minute, hour, day, week, month

    var calendarComponent: Calendar.Component {
        switch self {
        case .fiveMinute: return .minute
        case .minute: return .minute
        case .hour:   return .hour
        case .day:    return .day
        case .week:   return .weekOfYear
        case .month:  return .month
        }
    }

    /// Step value for advancing to the next bucket
    var stepValue: Int {
        switch self {
        case .fiveMinute: return 5
        default: return 1
        }
    }

    /// Cases available for session detail granularity picker
    static var sessionCases: [TrendGranularity] {
        [.minute, .hour, .day]
    }

    /// Truncate a date to the start of this granularity's bucket
    func bucketStart(for date: Date) -> Date {
        let cal = Calendar.current
        switch self {
        case .fiveMinute:
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            comps.minute = ((comps.minute ?? 0) / 5) * 5
            return cal.date(from: comps) ?? date
        case .minute:
            let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return cal.date(from: comps) ?? date
        case .hour:
            let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
            return cal.date(from: comps) ?? date
        case .day:
            return cal.startOfDay(for: date)
        case .week:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return cal.date(from: comps) ?? cal.startOfDay(for: date)
        case .month:
            let comps = cal.dateComponents([.year, .month], from: date)
            return cal.date(from: comps) ?? cal.startOfDay(for: date)
        }
    }

    /// X-axis date format string
    var dateFormatString: String {
        switch self {
        case .fiveMinute: return "HH:mm"
        case .minute: return "HH:mm"
        case .hour:   return "HH:00"
        case .day:    return "MM/dd"
        case .week:   return "MM/dd"
        case .month:  return "MMM"
        }
    }

    /// Auto-select granularity based on session duration
    static func autoSelect(for duration: TimeInterval?) -> TrendGranularity {
        guard let duration else { return .hour }
        if duration < 3600 { return .minute }       // < 1 hour
        if duration < 86400 { return .hour }         // < 24 hours
        return .day
    }
}

extension StatsPeriod {
    /// The trend chart granularity for this period type
    var trendGranularity: TrendGranularity {
        switch self {
        case .all:     return .day
        case .daily:   return .hour
        case .weekly:  return .day
        case .monthly: return .day
        }
    }
}
