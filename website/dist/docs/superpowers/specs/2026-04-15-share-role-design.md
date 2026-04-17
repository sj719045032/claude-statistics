# Share Role Card Feature Design

## Overview

Add a role-based sharing feature that turns each user's local analytics into a playful identity card.

The goal is not to show a cold ranking, but to generate a result that users want to repost:

- A clear role name
- A short funny subtitle
- Three proof metrics
- Two secondary badges
- A poster-style image exported directly from the app

This feature should work fully offline using the local analytics already parsed by Claude Statistics.

## Product Goals

- Increase repostability and word-of-mouth growth
- Make local analytics feel personal instead of purely numeric
- Reuse existing session, project, tool, model, token, and usage data
- Ship a stable first version without external image generation or backend services

## Non-Goals

- No public leaderboard
- No backend storage or user profile sync
- No AI-generated image pipeline in v1
- No negative or insulting role labels
- No role system that depends on absolute spending alone

## Design Principles

### 1. Identity over ranking

Users are more likely to share "I am the Vibe Coding King this week" than "I spent $12.84".

### 2. Behavior over totals

Roles should be assigned from usage patterns, not only large token or cost totals.

### 3. Proof over abstraction

Each role card must include 2 to 3 concrete numbers that justify the result.

### 4. Stable art direction

Use template-based poster rendering in SwiftUI first. Avoid runtime AI image generation until the feature proves value.

## Existing Data Available

The current app already exposes enough data to support role detection:

- `totalCost`, `sessionCount`, `messageCount`, `toolUseCount`, `modelBreakdown` in [AggregateStats.swift](/Users/tinystone/claude-statistics/ClaudeStatistics/Models/AggregateStats.swift:1)
- `totalTokens`, `toolUseCounts`, `fiveMinSlices`, `contextTokens`, `contextUsagePercent` in [Session.swift](/Users/tinystone/claude-statistics/ClaudeStatistics/Models/Session.swift:1)
- Project-level grouping and aggregates in [SessionViewModel.swift](/Users/tinystone/claude-statistics/ClaudeStatistics/ViewModels/SessionViewModel.swift:1)
- Provider quota and reset data in [UsageData.swift](/Users/tinystone/claude-statistics/ClaudeStatistics/Models/UsageData.swift:1)
- Period aggregation in [SessionDataStore.swift](/Users/tinystone/claude-statistics/ClaudeStatistics/Services/SessionDataStore.swift:1)

## Core User Flows

### Weekly Share Card

Best default entry point for repeat sharing.

Flow:

1. User opens a new "Share" action from Statistics period detail
2. App computes role for the selected week
3. App renders a poster card with role, subtitle, metrics, and badges
4. User exports image or uses macOS share sheet

### Monthly Share Card

Same flow, but with more stable behavior and fewer random swings.

### Milestone Share Card

Triggered from thresholds such as:

- first 1M tokens
- highest single-day record
- 7-day streak
- new peak tool usage

### Achievement Badge Share

Smaller one-off share objects for specific dimensions:

- Night Owl
- Tool Summoner
- Multi-Model Director
- Long Context Tamer

## Share Card Types

### Type A: Role Poster

Primary growth asset.

Fields:

- role name
- funny subtitle
- time scope
- 3 proof metrics
- 2 badges
- provider or multi-provider marker
- app branding

### Type B: Milestone Poster

For exceptional growth or first-time achievements.

Fields:

- milestone title
- record value
- comparison baseline
- date or period

### Type C: Compact Badge Card

Small square image for quick reposting.

Fields:

- badge name
- one-line description
- one supporting metric

## Recommended v1 Scope

Ship only one polished path first:

- Weekly role poster
- Monthly role poster
- Export as PNG
- Native share sheet

Skip milestone and badge-only cards until the base role system is stable.

## Role System

## Role Assignment Model

Use a weighted score per role and choose the highest-scoring role as the primary identity.

Each role score should combine:

- normalized absolute metrics within the selected period
- deviation from the user's own recent baseline
- lightweight thresholds to block obviously wrong matches

Recommended formula:

```text
roleScore = 0.65 * currentPeriodScore
          + 0.35 * personalBaselineLift
          + thresholdBonus
```

Where:

- `currentPeriodScore` is the weighted sum of normalized metrics inside the selected week or month
- `personalBaselineLift` compares the selected period against the user's rolling 30-day average
- `thresholdBonus` is a small fixed bonus when the user strongly fits a role

This avoids a system where only heavy users get interesting results.

## Primary Roles

### 1. Vibe Coding King

Meaning:
High activity, high tool usage, high project spread, strong builder energy.

Signal candidates:

- high session count
- high tool use total
- high project count
- high active day count

Suggested score:

```text
0.30 * norm(toolUseCount)
+ 0.25 * norm(sessionCount)
+ 0.20 * norm(projectCount)
+ 0.15 * norm(messageCount)
+ 0.10 * norm(activeDayCount)
```

Subtitle examples:

- Not writing code, but orchestrating it
- Opened one more terminal and called it strategy

Visual direction:

- crown
- terminal windows
- electric gold / orange

### 2. Tool Summoner

Meaning:
Strong dependence on tool calls and command-driven workflows.

Signal candidates:

- very high tool-to-message ratio
- multiple tool categories used
- long tail of tool usage

Suggested score:

```text
0.45 * norm(toolUsePerMessage)
+ 0.30 * norm(toolCategoryCount)
+ 0.25 * norm(toolUseCount)
```

Subtitle examples:

- If it can be called, you called it
- Keyboard first, consequences later

Visual direction:

- runes
- wrench
- glowing command line strips

### 3. Context Beast Tamer

Meaning:
Regularly runs large-context sessions and keeps them under control.

Signal candidates:

- high context usage percent
- high cache read tokens
- long session duration
- large per-session token totals

Suggested score:

```text
0.35 * norm(avgContextUsagePercent)
+ 0.30 * norm(cacheReadTokens)
+ 0.20 * norm(longSessionRatio)
+ 0.15 * norm(avgTokensPerSession)
```

Subtitle examples:

- You do not fear long prompts
- Turns giant context windows into domestic animals

Visual direction:

- chained dragon
- giant scroll
- teal / indigo

### 4. Night Shift Engineer

Meaning:
Heavy late-night activity pattern.

Signal candidates:

- 22:00 to 04:00 token share
- 22:00 to 04:00 session share
- repeated late-night streaks

Suggested score:

```text
0.50 * norm(nightTokenRatio)
+ 0.30 * norm(nightSessionRatio)
+ 0.20 * norm(nightActiveDayCount)
```

Subtitle examples:

- Most commits should probably have been sleep
- The moon saw every prompt

Visual direction:

- moonlit skyline
- green phosphor terminal glow

### 5. Multi-Model Director

Meaning:
Switches providers and models strategically.

Signal candidates:

- provider count
- model count
- model concentration inverse
- balanced distribution across models

Suggested score:

```text
0.35 * norm(providerCount)
+ 0.35 * norm(modelCount)
+ 0.20 * norm(modelEntropy)
+ 0.10 * norm(crossProviderSessionRatio)
```

Subtitle examples:

- Casting models like a film director
- Every task gets a different lead actor

Visual direction:

- camera rig
- stacked masks
- split-color backgrounds

### 6. Sprint Hacker

Meaning:
Explosive short-period output with visible peaks.

Signal candidates:

- highest single-day share of weekly total
- high 5-minute peak slices
- bursty session distribution

Suggested score:

```text
0.40 * norm(singleDayPeakRatio)
+ 0.35 * norm(topFiveMinutePeak)
+ 0.25 * norm(burstinessIndex)
```

Subtitle examples:

- Quiet until suddenly not
- Compresses a week into one evening

Visual direction:

- speed lines
- red / orange heat

### 7. Full-Stack Pathfinder

Meaning:
Works across many projects and keeps steady output.

Signal candidates:

- high project count
- strong active day coverage
- medium-to-high sessions without one huge spike

Suggested score:

```text
0.35 * norm(projectCount)
+ 0.35 * norm(activeDayCoverage)
+ 0.20 * inverse(singleDayPeakRatio)
+ 0.10 * norm(sessionCount)
```

Subtitle examples:

- New repo, who dis
- Treats project trees like an overworld map

Visual direction:

- map grid
- flags
- layered terrain shapes

### 8. Efficient Operator

Meaning:
Produces strong output with relatively restrained cost.

Signal candidates:

- high messages per dollar
- high tokens per dollar
- low waste relative to output

Suggested score:

```text
0.40 * norm(tokensPerDollar)
+ 0.35 * norm(messagesPerDollar)
+ 0.25 * inverse(costPerSession)
```

Guardrail:
Only show this role when cost data quality is acceptable and period volume is above a small minimum.

Subtitle examples:

- Maximum throughput, minimum drama
- Runs the stack like a control room

Visual direction:

- gauges
- cool blue / green

## Role Guardrails

To reduce bad assignments:

- require a minimum activity floor before assigning playful high-energy roles
- avoid `Efficient Operator` when cost is mostly estimated and sample size is too small
- avoid `Multi-Model Director` unless at least 2 models are meaningfully used
- avoid `Night Shift Engineer` unless night activity is consistent across more than 1 day

Fallback role:

- `Steady Builder`

This is the safe default for lower-volume or balanced users.

## Secondary Badges

Badges give variety even when the primary role repeats.

Recommended v1 badge pool:

- `Night Owl`
- `Weekend Crafter`
- `Long Session Player`
- `Cache Wizard`
- `Opus Loyalist`
- `Sonnet Specialist`
- `Gemini Flash Runner`
- `Tool Addict`
- `Project Hopper`
- `Consistency Machine`
- `Cost Minimalist`
- `Peak Day Monster`

Badge selection rule:

- compute all badge scores independently
- take the top 2 badges that do not overlap too much semantically with the primary role

## Derived Metrics Needed

Most are already derivable from current data:

- `sessionCount`
- `messageCount`
- `toolUseCount`
- `toolUsePerMessage`
- `projectCount`
- `activeDayCount`
- `activeDayCoverage`
- `providerCount`
- `modelCount`
- `modelEntropy`
- `avgTokensPerSession`
- `cacheReadTokens`
- `avgContextUsagePercent`
- `nightTokenRatio`
- `nightSessionRatio`
- `singleDayPeakRatio`
- `topFiveMinutePeak`
- `tokensPerDollar`
- `messagesPerDollar`
- `costPerSession`

## Data Aggregation Strategy

### Period Scope

Compute share cards from a selected period object:

- weekly card from a `PeriodStats` week window
- monthly card from a `PeriodStats` month window

### New Aggregation Layer

Add a dedicated share metrics aggregator rather than overloading view code.

Recommended model:

```swift
struct ShareMetrics {
    let period: DateInterval
    let providerKinds: Set<ProviderKind>
    let sessionCount: Int
    let messageCount: Int
    let totalTokens: Int
    let totalCost: Double
    let projectCount: Int
    let toolUseCount: Int
    let toolCategoryCount: Int
    let activeDayCount: Int
    let nightSessionCount: Int
    let nightTokenCount: Int
    let cacheReadTokens: Int
    let averageContextUsagePercent: Double
    let averageTokensPerSession: Double
    let modelCount: Int
    let modelEntropy: Double
    let peakDayTokens: Int
    let peakFiveMinuteTokens: Int
}
```

Then compute:

- primary role
- secondary badges
- proof metrics
- marketing copy

from this normalized intermediate data.

## Role Output Model

Recommended output model:

```swift
struct ShareRoleResult {
    let roleID: ShareRoleID
    let roleName: String
    let subtitle: String
    let summary: String
    let visualTheme: ShareVisualTheme
    let badges: [ShareBadge]
    let proofMetrics: [ShareProofMetric]
}
```

### Proof Metric Rules

Each role card should show exactly 3 proof metrics.

Examples:

- `47 sessions this week`
- `312 tool calls`
- `8 projects touched`
- `61% of usage happened after 10 PM`
- `3 providers, 7 models`

Do not expose too many raw numbers.

## Copy System

Each role should have:

- one stable title
- 3 to 5 subtitle variants
- 2 to 3 short summary variants

Example:

```text
Role: Vibe Coding King
Subtitle variant A: Not writing code, but orchestrating it
Subtitle variant B: One more terminal window counts as leadership
```

Variant selection should be deterministic from the current period seed so export is stable.

## Visual System

## v1 Rendering Strategy

Use SwiftUI poster templates rendered locally to image.

Benefits:

- deterministic output
- fast iteration
- no external dependency
- easy localization
- easy A/B iteration on themes

### Layout

Recommended poster sizes:

- `1200x1600` for 4:5
- `1080x1080` for square

Recommended sections:

1. top badge strip
2. main role title
3. subtitle
4. hero art area
5. proof metrics
6. footer branding

### Theme Tokens

Each role should define:

- primary color
- secondary color
- background gradient
- icon set
- decorative motif
- typography emphasis

### Art Direction

Do not make the card look like a default analytics screenshot.

It should feel like:

- a game title card
- an annual report poster
- a social-ready identity badge

## Export and Sharing

## Export Methods

v1 should support:

- save PNG
- copy image to clipboard
- open native macOS share sheet

## Rendering Path

Recommended implementation:

1. SwiftUI `ShareCardView`
2. render using `ImageRenderer`
3. export PNG data
4. feed PNG to save panel or share sheet

## Placement in UI

Recommended entry points:

- Statistics period detail header: `Share This Period`
- All-time stats area: `Share My Role`
- Context menu on period rows

v1 should start with one obvious action in period detail only.

## Suggested File Additions

| File | Purpose |
|------|---------|
| `Models/ShareRole.swift` | role IDs, theme data, badge types |
| `Models/ShareMetrics.swift` | derived metrics used for role scoring |
| `Services/ShareRoleEngine.swift` | score roles and produce `ShareRoleResult` |
| `Services/ShareMetricsBuilder.swift` | aggregate metrics from parsed sessions |
| `Views/ShareCardView.swift` | poster rendering |
| `Views/SharePreviewView.swift` | preview + export actions |
| `Utilities/ShareImageExporter.swift` | `ImageRenderer` to PNG export |

## Analytics and Iteration

Even in a local-first app, the feature should be designed for future refinement.

Questions to validate:

- Which role names are most frequently exported
- Which card layout gets kept versus dismissed
- Which proof metrics users find most "showable"

For now, structure the system so titles, subtitles, and themes are easy to tweak in code.

## Phased Rollout

### Phase 1

- weekly and monthly role poster
- 6 to 8 roles
- 10 to 12 badges
- PNG export
- share sheet

### Phase 2

- milestone posters
- more playful subtitle variants
- alternate visual themes
- square and story layouts

### Phase 3

- animated export
- richer provider-aware roles
- optional online template pack updates

## Risks

### Role feels arbitrary

Mitigation:

- always show proof metrics
- use threshold guardrails
- avoid overfitting to one single metric

### Cards look too generic

Mitigation:

- make themes role-specific
- use stronger iconography and bold composition
- avoid screenshot-like panels

### Repeated users see the same role too often

Mitigation:

- add badge variety
- use subtitle variants
- bias scoring slightly toward role changes only when the score gap is small

### Low-volume users get weak results

Mitigation:

- fallback role
- baseline-relative scoring
- use positive framing for lower activity

## Recommendation

Implement v1 around one strong object:

- `weekly or monthly role poster generated from local period analytics`

This has the best balance of:

- product appeal
- engineering simplicity
- visual consistency
- future extensibility
