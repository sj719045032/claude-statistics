# Trend Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add dual Y-axis line charts (tokens + cost) to Session detail and Statistics period detail views with granularity switching.

**Architecture:** A shared `TrendChartView` component built with SwiftUI Charts renders normalized dual-axis line data. Two separate data aggregation paths feed it: message-level parsing for sessions, session-level bucketing for period stats.

**Tech Stack:** SwiftUI Charts (macOS 13+, `import Charts`), existing SwiftUI app patterns (`SectionCard`, `@State`, async `.task`)

**Spec:** `docs/superpowers/specs/2026-03-23-trend-chart-design.md`

---

### Task 1: Data Model — TrendDataPoint + TrendGranularity

**Files:**
- Create: `ClaudeStatistics/Models/TrendDataPoint.swift`

- [ ] **Step 1: Create TrendDataPoint.swift**

```swift
import Foundation

struct TrendDataPoint: Identifiable {
    let id = UUID()
    let time: Date
    let tokens: Int       // input + output + cacheCreation + cacheRead
    let cost: Double      // USD
}

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

    /// Truncate a date to the start of this granularity's bucket
    func bucketStart(for date: Date) -> Date {
        let cal = Calendar.current
        switch self {
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
        case .daily:   return .hour
        case .weekly:  return .day
        case .monthly: return .week
        case .yearly:  return .month
        }
    }
}
```

- [ ] **Step 2: Add file to Xcode project**

The file must appear in the Xcode project. Since the project uses file system references, adding the file to the correct directory should suffice. If not, open `ClaudeStatistics.xcodeproj/project.pbxproj` and verify the file is included in the target's Sources build phase.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -scheme ClaudeStatistics -destination 'platform=macOS' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add ClaudeStatistics/Models/TrendDataPoint.swift
git commit -m "feat: add TrendDataPoint and TrendGranularity data models"
```

---

### Task 2: Chart Component — TrendChartView

**Files:**
- Create: `ClaudeStatistics/Views/TrendChartView.swift`

- [ ] **Step 1: Create TrendChartView.swift**

```swift
import SwiftUI
import Charts

struct TrendChartView: View {
    let dataPoints: [TrendDataPoint]
    let granularity: TrendGranularity

    private var maxTokens: Int {
        dataPoints.map(\.tokens).max() ?? 0
    }
    private var maxCost: Double {
        dataPoints.map(\.cost).max() ?? 0
    }
    /// Scale factor to normalize cost into the token value range
    private var scaleFactor: Double {
        guard maxCost > 0, maxTokens > 0 else { return 1.0 }
        return Double(maxTokens) / maxCost
    }

    var body: some View {
        if dataPoints.isEmpty {
            emptyState
        } else {
            chartContent
                .frame(height: 200)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text("No trend data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(height: 100)
    }

    @ViewBuilder
    private var chartContent: some View {
        let useSingleAxis = maxTokens == 0 || maxCost == 0

        Chart {
            ForEach(dataPoints) { point in
                if dataPoints.count == 1 {
                    // Single point: use PointMark
                    if maxTokens > 0 {
                        PointMark(
                            x: .value("Time", point.time),
                            y: .value("Tokens", point.tokens)
                        )
                        .foregroundStyle(.blue)
                        .symbolSize(30)
                    }
                    if maxCost > 0 {
                        PointMark(
                            x: .value("Time", point.time),
                            y: .value("Tokens", useSingleAxis ? Int(point.cost * 1000) : Int(point.cost * scaleFactor))
                        )
                        .foregroundStyle(.orange)
                        .symbolSize(30)
                    }
                } else {
                    // Multiple points: use LineMark
                    if maxTokens > 0 {
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("Tokens", point.tokens),
                            series: .value("Series", "Tokens")
                        )
                        .foregroundStyle(.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }
                    if maxCost > 0 {
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("Tokens", useSingleAxis ? Int(point.cost * 1000) : Int(point.cost * scaleFactor)),
                            series: .value("Series", "Cost")
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(formatAxisDate(date))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            // Left axis: tokens
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let intVal = value.as(Int.self) {
                        Text(abbreviateNumber(intVal))
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }
                }
            }
            // Right axis: cost (reverse-mapped from normalized values)
            if !useSingleAxis {
                AxisMarks(position: .trailing) { value in
                    AxisValueLabel {
                        if let intVal = value.as(Int.self) {
                            let realCost = Double(intVal) / scaleFactor
                            Text(abbreviateCost(realCost))
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .chartLegend(position: .top) {
            HStack(spacing: 12) {
                if maxTokens > 0 {
                    legendItem(color: .blue, label: "Tokens")
                }
                if maxCost > 0 {
                    legendItem(color: .orange, label: "Cost")
                }
            }
            .font(.system(size: 10))
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
        }
    }

    private func formatAxisDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = granularity.dateFormatString
        return fmt.string(from: date)
    }

    private func abbreviateNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func abbreviateCost(_ cost: Double) -> String {
        if cost >= 1.0 { return String(format: "$%.1f", cost) }
        if cost >= 0.01 { return String(format: "$%.2f", cost) }
        return String(format: "$%.3f", cost)
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme ClaudeStatistics -destination 'platform=macOS' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add ClaudeStatistics/Views/TrendChartView.swift
git commit -m "feat: add TrendChartView dual Y-axis line chart component"
```

---

### Task 3: Session Trend Data Aggregation — parseTrendData

**Files:**
- Modify: `ClaudeStatistics/Services/TranscriptParser.swift`

This method reuses the existing `parseSession` deduplication logic (message ID tracking, last entry wins for streaming) but accumulates into time buckets instead of session-level totals.

- [ ] **Step 1: Add parseTrendData method to TranscriptParser**

Add the following method after the `parseSession(at:)` method (after line 143 in `TranscriptParser.swift`):

```swift
/// Parse JSONL into time-bucketed trend data points for chart display
func parseTrendData(from filePath: String, granularity: TrendGranularity) -> [TrendDataPoint] {
    guard let data = FileManager.default.contents(atPath: filePath),
          let content = String(data: data, encoding: .utf8) else {
        return []
    }

    let decoder = JSONDecoder()
    let lines = content.components(separatedBy: "\n")

    // Per-message: track last entry (streaming dedup), keyed by message ID
    struct MsgData {
        var timestamp: Date
        var model: String
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheCreationTotalTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreation5mTokens: Int = 0
        var cacheCreation1hTokens: Int = 0
    }
    var messageData: [String: MsgData] = [:]

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
        guard let entry = try? decoder.decode(TranscriptEntry.self, from: lineData) else { continue }
        guard entry.type == "assistant",
              let message = entry.message,
              let usage = message.usage,
              let timestamp = entry.timestampDate else { continue }

        let isSynthetic = message.model == "<synthetic>"
        guard !isSynthetic else { continue }

        let msgId = message.id ?? UUID().uuidString
        let model = message.model ?? "Unknown"

        messageData[msgId] = MsgData(
            timestamp: timestamp,
            model: model,
            inputTokens: usage.inputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0,
            cacheCreationTotalTokens: usage.cacheCreationInputTokens ?? 0,
            cacheReadTokens: usage.cacheReadInputTokens ?? 0,
            cacheCreation5mTokens: usage.cacheCreation?.ephemeral5mInputTokens ?? 0,
            cacheCreation1hTokens: usage.cacheCreation?.ephemeral1hInputTokens ?? 0
        )
    }

    // Bucket by granularity
    var buckets: [Date: (tokens: Int, cost: Double)] = [:]
    for (_, msg) in messageData {
        let bucket = granularity.bucketStart(for: msg.timestamp)
        let tokens = msg.inputTokens + msg.outputTokens + msg.cacheCreationTotalTokens + msg.cacheReadTokens
        let cost = ModelPricing.estimateCost(
            model: msg.model,
            inputTokens: msg.inputTokens,
            outputTokens: msg.outputTokens,
            cacheCreation5mTokens: msg.cacheCreation5mTokens,
            cacheCreation1hTokens: msg.cacheCreation1hTokens,
            cacheCreationTotalTokens: msg.cacheCreationTotalTokens,
            cacheReadTokens: msg.cacheReadTokens
        )
        var existing = buckets[bucket, default: (tokens: 0, cost: 0)]
        existing.tokens += tokens
        existing.cost += cost
        buckets[bucket] = existing
    }

    return buckets.map { TrendDataPoint(time: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
        .sorted { $0.time < $1.time }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme ClaudeStatistics -destination 'platform=macOS' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add ClaudeStatistics/Services/TranscriptParser.swift
git commit -m "feat: add parseTrendData for session-level trend aggregation"
```

---

### Task 4: Period Trend Data Aggregation — aggregateTrendData

**Files:**
- Modify: `ClaudeStatistics/Services/SessionDataStore.swift`

Note: The spec's original signature was `aggregateTrendData(sessions:granularity:)`, but this plan uses `aggregateTrendData(for:periodType:)` instead — more practical since `SessionDataStore` already holds `sessions` and `parsedStats`, so the caller only passes the period context. Granularity is derived from `periodType.trendGranularity` (added in Task 1).

Known limitation: A long-running session spanning multiple time buckets only appears in its start-time bucket.

- [ ] **Step 1: Add aggregateTrendData method to SessionDataStore**

Add the following method in the `// MARK: - Computed` section (after `visibleModelBreakdown`, around line 297):

```swift
/// Aggregate trend data for a given period from parsed session stats
func aggregateTrendData(for period: PeriodStats, periodType: StatsPeriod) -> [TrendDataPoint] {
    let granularity = periodType.trendGranularity

    var buckets: [Date: (tokens: Int, cost: Double)] = [:]

    for (sessionId, stats) in parsedStats {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { continue }
        let sessionDate = stats.startTime ?? session.lastModified
        let sessionPeriodStart = periodType.startOfPeriod(for: sessionDate)

        // Only include sessions in this period
        guard sessionPeriodStart == period.period else { continue }

        let bucket = granularity.bucketStart(for: sessionDate)
        let tokens = stats.totalTokens
        let cost = stats.estimatedCost

        var existing = buckets[bucket, default: (tokens: 0, cost: 0)]
        existing.tokens += tokens
        existing.cost += cost
        buckets[bucket] = existing
    }

    return buckets.map { TrendDataPoint(time: $0.key, tokens: $0.value.tokens, cost: $0.value.cost) }
        .sorted { $0.time < $1.time }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme ClaudeStatistics -destination 'platform=macOS' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add ClaudeStatistics/Services/SessionDataStore.swift
git commit -m "feat: add aggregateTrendData for period-level trend chart"
```

---

### Task 5: Integrate Trend Chart into SessionDetailView

**Files:**
- Modify: `ClaudeStatistics/Views/SessionDetailView.swift`

- [ ] **Step 1: Add localization keys**

Add `"detail.trend"` to both localization files:

In `ClaudeStatistics/Resources/en.lproj/Localizable.strings`, add after `"detail.tools"`:
```
"detail.trend" = "Trend";
```

In `ClaudeStatistics/Resources/zh-Hans.lproj/Localizable.strings`, add at the equivalent location:
```
"detail.trend" = "趋势";
```

- [ ] **Step 2: Add state variables and trend chart card**

At the top of `SessionDetailView`, add these state variables alongside existing `@State` declarations (around line 15):

```swift
@State private var trendGranularity: TrendGranularity = .hour
@State private var trendData: [TrendDataPoint] = []
@State private var isTrendLoading = false
```

In the `statsContent(_ stats:)` method, insert the trend chart card **after the Overview card** (after the `SectionCard` at line 178, before the Context window card). Add:

```swift
// Trend chart
SectionCard {
    VStack(spacing: 8) {
        HStack {
            Label("detail.trend", systemImage: "chart.line.uptrend.xyaxis")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: $trendGranularity) {
                ForEach(TrendGranularity.sessionCases, id: \.self) { g in
                    Text(g.rawValue.capitalized).tag(g)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }

        if isTrendLoading {
            ProgressView()
                .scaleEffect(0.6)
                .frame(height: 100)
                .frame(maxWidth: .infinity)
        } else {
            TrendChartView(dataPoints: trendData, granularity: trendGranularity)
        }
    }
}
.task {
    trendGranularity = TrendGranularity.autoSelect(for: stats.duration)
    await loadTrendData()
}
.onChange(of: trendGranularity) { _, _ in
    Task { await loadTrendData() }
}
```

Add the `loadTrendData` helper method as a private method on `SessionDetailView`:

```swift
private func loadTrendData() async {
    isTrendLoading = true
    let path = session.filePath
    let gran = trendGranularity
    let data = await Task.detached {
        TranscriptParser.shared.parseTrendData(from: path, granularity: gran)
    }.value
    isTrendLoading = false
    trendData = data
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -scheme ClaudeStatistics -destination 'platform=macOS' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Launch app and visually verify**

Open the app, navigate to a session detail. Verify:
- Trend chart appears after the overview card
- Segmented picker shows Minute/Hour/Day
- Default granularity is auto-selected based on session duration
- Switching granularity reloads the chart
- Blue line for tokens, orange line for cost
- Left axis shows token counts, right axis shows cost
- Empty state shown for sessions with no data

- [ ] **Step 5: Commit**

```bash
git add ClaudeStatistics/Views/SessionDetailView.swift
git commit -m "feat: integrate trend chart into session detail view"
```

---

### Task 6: Integrate Trend Chart into PeriodDetailView

**Files:**
- Modify: `ClaudeStatistics/Views/StatisticsView.swift`

- [ ] **Step 1: Add store dependency and trend data to PeriodDetailView**

`PeriodDetailView` currently does not have access to `SessionDataStore`. Add it as a parameter.

In `StatisticsView`, update the `PeriodDetailView` call site (around line 14) to pass the store:

```swift
PeriodDetailView(
    stat: detail,
    periodType: store.selectedPeriod,
    store: store,
    onBack: { selectedPeriodDetail = nil }
)
```

In `PeriodDetailView` struct (line 461), add the store property and trend state:

```swift
struct PeriodDetailView: View {
    let stat: PeriodStats
    let periodType: StatsPeriod
    let store: SessionDataStore    // NEW
    let onBack: () -> Void

    @State private var trendData: [TrendDataPoint] = []  // NEW
```

Insert the trend chart card in the ScrollView content, **after the Overview card** (after the `SectionCard` at line 502, before `CostModelsCard`):

```swift
// Trend chart
SectionCard {
    VStack(spacing: 8) {
        Label("detail.trend", systemImage: "chart.line.uptrend.xyaxis")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

        TrendChartView(dataPoints: trendData, granularity: periodType.trendGranularity)
    }
}
.task {
    trendData = store.aggregateTrendData(for: stat, periodType: periodType)
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild build -scheme ClaudeStatistics -destination 'platform=macOS' -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Launch app and visually verify**

Open the app, navigate to Statistics tab → tap a period to open detail. Verify:
- Trend chart appears after the overview card
- No granularity picker (fixed by period type)
- Daily period shows hourly buckets, weekly shows daily, etc.
- Chart displays correctly with token and cost lines

- [ ] **Step 4: Commit**

```bash
git add ClaudeStatistics/Views/StatisticsView.swift
git commit -m "feat: integrate trend chart into period detail view"
```

---

### Task 7: Final Polish and Build Verification

**Files:**
- All modified files

- [ ] **Step 1: Full clean build**

Run: `xcodebuild clean build -scheme ClaudeStatistics -destination 'platform=macOS' -quiet 2>&1 | tail -10`
Expected: BUILD SUCCEEDED with no warnings related to our changes

- [ ] **Step 2: Launch and smoke test both chart locations**

1. Open app → Sessions → tap any session → verify trend chart renders
2. Switch granularity picker → verify chart updates
3. Go back → Statistics tab → tap a daily period → verify trend chart
4. Switch to weekly/monthly/yearly → tap a period → verify chart adapts granularity

- [ ] **Step 3: Final commit if any polish needed**

```bash
git add -A
git commit -m "feat: complete trend chart feature for session and period detail views"
```
