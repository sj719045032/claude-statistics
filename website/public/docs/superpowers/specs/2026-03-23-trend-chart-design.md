# Trend Chart Feature Design

## Overview

Add trend line charts to Session detail view and Statistics period detail view, showing token usage and cost over time with switchable granularity.

## Requirements

- **Session detail**: Dual Y-axis line chart (left: total tokens, right: cost $), granularity switchable between minute/hour/day, default auto-selected by session duration
- **Statistics period detail**: Same chart style, granularity fixed by period type (daily->hourly, weekly->daily, monthly->weekly, yearly->monthly)
- **Chart framework**: SwiftUI Charts (macOS 13+, `import Charts` required, project targets macOS 14.0)
- **Reusable component**: Single `TrendChartView` shared by both scenarios

## Data Model

### TrendDataPoint

```swift
struct TrendDataPoint: Identifiable {
    let id = UUID()
    let time: Date        // Bucket start time
    let tokens: Int       // Total tokens (input + output + cacheCreation + cacheRead) in this bucket
    let cost: Double      // Cost ($) in this bucket
}
```

Note: `tokens` includes all token types (input, output, cache creation, cache read) to match the existing `totalTokens` convention used in `SessionStats` and `PeriodStats`.

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

    /// Cases available for session detail granularity picker
    static var sessionCases: [TrendGranularity] {
        [.minute, .hour, .day]
    }
}
```

## Chart Component

### TrendChartView

A generic SwiftUI Charts view accepting `[TrendDataPoint]` and `TrendGranularity`. Requires `import Charts`.

Key characteristics:
- **Two LineMark series**: blue for tokens, orange for cost
- **Dual Y-axis**: Both series share a single Chart Y domain. Cost values are normalized to the token value range for visual alignment. Left axis shows token values, right axis shows true cost values via reverse-mapped labels.
- **Normalization formula**: `normalizedCost = cost * (maxTokens / maxCost)`. Right axis labels: `displayCost = axisValue * (maxCost / maxTokens)`. When either `maxTokens` or `maxCost` is zero, show only the non-zero series as a single Y-axis chart.
- **X-axis formatting**: Varies by granularity — minute: "HH:mm", hour: "HH:00", day: "MM/dd", week: "MM/dd", month: "MMM"
- **Legend**: Top position, showing "Tokens" (blue) and "Cost" (orange)
- **Container**: Wrapped in `SectionCard { ... }` (content-only closure, no title parameter — place label inside content), height ~200pt
- **Empty state**: Show placeholder text when no data points
- **Single data point**: Display as `PointMark` instead of `LineMark`, since a single-point line is invisible

## Data Aggregation

### Session Detail — parseTrendData

New instance method on `TranscriptParser.shared` (matching existing singleton pattern):

```swift
func parseTrendData(from filePath: String,
                    granularity: TrendGranularity) -> [TrendDataPoint]
```

Logic:
1. Parse JSONL line by line, reusing the existing `parseSession` deduplication approach: track message IDs so that streaming entries are deduplicated (last entry per message ID wins)
2. For each deduplicated assistant message, extract: `timestamp`, all token types (`inputTokens + outputTokens + cacheCreationInputTokens + cacheReadInputTokens`), model name, and compute cost per-message via `ModelPricing` using the message's specific model (not a session-level model)
3. Cache token cost must respect the 5m/1h tier breakdown when available (same logic as existing `ModelPricing.calculateCost`)
4. Truncate timestamp to bucket start using `granularity.calendarComponent`
5. Accumulate tokens and cost per bucket
6. Return sorted by time

Default granularity auto-selection:
- Session duration < 1 hour -> minute
- Session duration < 24 hours -> hour
- Session duration >= 24 hours -> day

### Statistics Period Detail — aggregateTrendData

New instance method on `SessionDataStore`:

```swift
func aggregateTrendData(sessions: [(Session, SessionStats)],
                        granularity: TrendGranularity) -> [TrendDataPoint]
```

Logic:
1. Filter sessions belonging to the target period
2. Use each session's `startTime`, `totalTokens` (all token types included), `estimatedCost` as a data point
3. Truncate time to bucket, accumulate per bucket
4. Return sorted by time

Known limitation: A long-running session spanning multiple time buckets will only appear in its start-time bucket. This is an acceptable trade-off for simplicity.

Granularity mapping from StatsPeriod:
- `.daily` -> `.hour`
- `.weekly` -> `.day`
- `.monthly` -> `.week`
- `.yearly` -> `.month`

## View Integration

### SessionDetailView

Insert trend chart card after the Overview card:

```swift
SectionCard {
    Label("Trend", systemImage: "chart.line.uptrend.xyaxis")
        .font(.headline)

    Picker("Granularity", selection: $granularity) {
        ForEach(TrendGranularity.sessionCases, id: \.self) { g in
            Text(g.rawValue.capitalized).tag(g)
        }
    }
    .pickerStyle(.segmented)

    TrendChartView(dataPoints: trendData, granularity: granularity)
}
```

- `@State var granularity: TrendGranularity` — default auto-computed from session duration
- Data parsed async in `.task` / `onChange(of: granularity)`, avoids UI blocking
- Picker shows only `TrendGranularity.sessionCases` (minute, hour, day)

### PeriodDetailView (in StatisticsView.swift)

Insert trend chart card after Overview card:

```swift
SectionCard {
    Label("Trend", systemImage: "chart.line.uptrend.xyaxis")
        .font(.headline)

    TrendChartView(dataPoints: trendData, granularity: fixedGranularity)
}
```

- Granularity determined by `StatsPeriod`, no user picker needed
- Data aggregated from `SessionDataStore.parsedStats` on view load

## File Changes

| File | Change |
|------|--------|
| New `Models/TrendDataPoint.swift` | `TrendDataPoint` struct + `TrendGranularity` enum |
| New `Views/TrendChartView.swift` | Reusable dual Y-axis line chart component (`import Charts`) |
| Modify `Services/TranscriptParser.swift` | Add `parseTrendData(from:granularity:)` instance method |
| Modify `Services/SessionDataStore.swift` | Add `aggregateTrendData(sessions:granularity:)` instance method |
| Modify `Views/SessionDetailView.swift` | Insert trend chart card with granularity picker |
| Modify `Views/StatisticsView.swift` | Insert trend chart card in `PeriodDetailView` |

Note: SwiftUI Charts framework is available from macOS 13+. The project targets macOS 14.0, so no deployment target change is needed. The Charts framework will be auto-linked via `import Charts`.

## Non-Goals

- No third-party charting libraries
- No interactive tooltips or crosshair (can be added later)
- No data export or screenshot functionality
- No animation on data load (keep it simple)
