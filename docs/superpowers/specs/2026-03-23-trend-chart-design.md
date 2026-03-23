# Trend Chart Feature Design

## Overview

Add trend line charts to Session detail view and Statistics period detail view, showing token usage and cost over time with switchable granularity.

## Requirements

- **Session detail**: Dual Y-axis line chart (left: total tokens, right: cost $), granularity switchable between minute/hour/day, default auto-selected by session duration
- **Statistics period detail**: Same chart style, granularity fixed by period type (daily->hourly, weekly->daily, monthly->weekly, yearly->monthly)
- **Chart framework**: SwiftUI Charts (macOS 13+)
- **Reusable component**: Single `TrendChartView` shared by both scenarios

## Data Model

### TrendDataPoint

```swift
struct TrendDataPoint: Identifiable {
    let id = UUID()
    let time: Date        // Bucket start time
    let tokens: Int       // Total tokens (input + output) in this bucket
    let cost: Double      // Cost ($) in this bucket
}
```

### TrendGranularity

```swift
enum TrendGranularity: String, CaseIterable {
    case minute, hour, day, week, month

    var calendarComponent: Calendar.Component {
        switch self {
        case .minute: return .minute
        case .hour:   return .hour
        case .day:    return .day
        case .week:   return .weekOfYear
        case .month:  return .month
        }
    }
}
```

## Chart Component

### TrendChartView

A generic SwiftUI Charts view accepting `[TrendDataPoint]` and `TrendGranularity`.

Key characteristics:
- **Two LineMark series**: blue for tokens, orange for cost
- **Dual Y-axis**: `AxisMarks(position: .leading)` for tokens, `AxisMarks(position: .trailing)` for cost
- **Normalization**: Cost values scaled to token value range for visual alignment; right axis labels display true cost values
- **X-axis formatting**: Varies by granularity — minute: "HH:mm", hour: "HH:00", day: "MM/dd", week: "MM/dd", month: "MMM"
- **Legend**: Top position, showing "Tokens" (blue) and "Cost" (orange)
- **Container**: Wrapped in `SectionCard`, height ~200pt
- **Empty state**: Show placeholder text when no data points

## Data Aggregation

### Session Detail — parseTrendData

New static method in `TranscriptParser`:

```swift
static func parseTrendData(from filePath: String,
                           granularity: TrendGranularity) -> [TrendDataPoint]
```

Logic:
1. Parse JSONL line by line, extract each assistant message's `timestamp`, `usage.inputTokens + outputTokens`, and computed cost (via `ModelPricing`)
2. Truncate timestamp to bucket start using `granularity.calendarComponent`
3. Accumulate tokens and cost per bucket
4. Return sorted by time

Default granularity auto-selection:
- Session duration < 1 hour -> minute
- Session duration < 24 hours -> hour
- Session duration >= 24 hours -> day

### Statistics Period Detail — aggregateTrendData

New static method in `SessionDataStore` or a utility:

```swift
static func aggregateTrendData(sessions: [(Session, SessionStats)],
                                granularity: TrendGranularity) -> [TrendDataPoint]
```

Logic:
1. Filter sessions belonging to the target period
2. Use each session's `startTime`, `totalInputTokens + totalOutputTokens`, `estimatedCost` as a data point
3. Truncate time to bucket, accumulate per bucket
4. Return sorted by time

Granularity mapping from StatsPeriod:
- `.daily` -> `.hour`
- `.weekly` -> `.day`
- `.monthly` -> `.week`
- `.yearly` -> `.month`

## View Integration

### SessionDetailView

Insert trend chart card after the Overview card:

```swift
SectionCard("Trend") {
    Picker("Granularity", selection: $granularity) {
        ForEach(TrendGranularity.allCases, id: \.self) { ... }
    }
    .pickerStyle(.segmented)

    TrendChartView(dataPoints: trendData, granularity: granularity)
}
```

- `@State var granularity: TrendGranularity` — default auto-computed from session duration
- Data parsed async in `.task` / `onChange(of: granularity)`, avoids UI blocking
- Only show minute/hour/day options (filter `allCases`)

### PeriodDetailView (in StatisticsView.swift)

Insert trend chart card after Overview card:

```swift
SectionCard("Trend") {
    TrendChartView(dataPoints: trendData, granularity: fixedGranularity)
}
```

- Granularity determined by `StatsPeriod`, no user picker needed
- Data aggregated from `SessionDataStore.parsedStats` on view load

## File Changes

| File | Change |
|------|--------|
| New `Models/TrendDataPoint.swift` | `TrendDataPoint` struct + `TrendGranularity` enum |
| New `Views/TrendChartView.swift` | Reusable dual Y-axis line chart component |
| Modify `Services/TranscriptParser.swift` | Add `parseTrendData(from:granularity:)` |
| Modify `Services/SessionDataStore.swift` | Add `aggregateTrendData(sessions:granularity:)` |
| Modify `Views/SessionDetailView.swift` | Insert trend chart card with granularity picker |
| Modify `Views/StatisticsView.swift` | Insert trend chart card in `PeriodDetailView` |

## Non-Goals

- No third-party charting libraries
- No interactive tooltips or crosshair (can be added later)
- No data export or screenshot functionality
- No animation on data load (keep it simple)
