# OpenAI Usage Monitor Design

## Overview

Add a third subscription usage provider for OpenAI Codex/ChatGPT OAuth accounts, alongside the existing Claude and Z.ai usage panels.

The feature should feel consistent with the current app and visually echo the compact quota presentation seen in Quotio and the progress-card presentation used for Z.ai, while preserving OpenAI's real quota semantics:

- **Current window** for the short rolling/session quota returned by OpenAI
- **Weekly usage** for the secondary weekly window returned by OpenAI

This is a read-only monitoring feature. It must not add an in-app OpenAI login flow or API key management.

## Requirements

- Data source is local Codex OAuth state from `~/.codex/auth.json`
- Only support Codex/ChatGPT OAuth mode (`auth_mode == "chatgpt"`)
- Do not support OpenAI API key mode
- Add a dedicated OpenAI usage toggle in Settings
- Show an OpenAI section in the Usage tab when the feature is enabled
- Display OpenAI's short window as **Current window**, not "5 hours"
- Display OpenAI's secondary window as **Weekly usage**
- Follow the current Claude failure behavior: invalid or expired auth shows an error message in UI, without in-app re-auth guidance
- Expand the menu bar label to show up to 3 compact usage items:
  - `C 42% Z 64% O 31%`
- Apply Quotio-style color thresholds and typography hierarchy to the percentages in the compact menu label

## Product Boundaries

- The app reads local Codex login state and uses it only to fetch usage data
- The app does not perform device-code login, browser OAuth, account switching, logout, or token editing
- The app may attempt silent token refresh using the stored refresh token when the access token is expired
- If silent refresh fails, the app surfaces the error and falls back to cached data when available
- OpenAI is treated as a third provider, not as a replacement for the existing Claude or Z.ai flows

## Architecture

### OpenAICredentialService

Create a dedicated credential reader for Codex auth:

```swift
final class OpenAICredentialService {
    static let shared = OpenAICredentialService()

    func loadAuthState() async -> OpenAIAuthState
}
```

Responsibilities:

- Read `~/.codex/auth.json`
- Validate that `auth_mode == "chatgpt"`
- Extract `tokens.access_token`, `tokens.refresh_token`, `tokens.id_token`, `tokens.account_id`
- Decode `id_token` when available to derive display metadata such as email and account plan hints
- Report a configuration state that distinguishes:
  - configured
  - missing auth file
  - unsupported auth mode
  - invalid token payload

This service should never store credentials in app-managed keychain entries because OpenAI is intentionally tied to the Codex login state already on disk.

### OpenAIUsageAPIService

Create a dedicated API service modeled after the existing Claude and Z.ai services:

```swift
final class OpenAIUsageAPIService {
    static let shared = OpenAIUsageAPIService()

    func fetchUsage() async throws -> OpenAIUsageData
    func loadFromCache() -> (data: OpenAIUsageData, fetchedAt: Date)?
}
```

Responsibilities:

- Call `https://chatgpt.com/backend-api/wham/usage`
- Send:
  - `Authorization: Bearer <access_token>`
  - `Accept: application/json`
  - `ChatGPT-Account-Id` when an account id is present
- Parse the usage response into the app's own display model
- Attempt silent refresh when the access token is expired and a refresh token exists
- Persist the latest successful fetch to `~/.claude-statistics/openai-usage-cache.json`

Use a separate cache file from Claude and Z.ai so provider failures remain isolated.

### OpenAIUsageViewModel

Add a third usage view model following the same responsibilities as the existing provider-specific view models:

```swift
@MainActor
final class OpenAIUsageViewModel: ObservableObject {
    @Published var usageData: OpenAIUsageData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastFetchedAt: Date?
    @Published var isConfigured = false
}
```

Responsibilities:

- Load cached data on startup
- Determine whether local OpenAI/Codex OAuth state is available
- Refresh usage on demand
- Participate in shared auto-refresh only when the new Settings toggle is enabled
- Expose computed values for:
  - current-window percent
  - weekly percent
  - reset countdown strings
  - menu bar display eligibility

## Data Model

Create `OpenAIUsageData.swift` with provider-specific models instead of reusing the Claude naming:

```swift
struct OpenAIUsageData: Codable, Equatable {
    let currentWindow: OpenAIUsageWindow?
    let weeklyWindow: OpenAIUsageWindow?
    let planType: String?
    let accountEmail: String?
}

struct OpenAIUsageWindow: Codable, Equatable {
    let utilization: Double
    let resetAt: Date?
}
```

Response mapping should preserve OpenAI's semantics:

- `rate_limit.primary_window.used_percent` -> `currentWindow.utilization`
- `rate_limit.primary_window.reset_at` -> `currentWindow.resetAt`
- `rate_limit.secondary_window.used_percent` -> `weeklyWindow.utilization`
- `rate_limit.secondary_window.reset_at` -> `weeklyWindow.resetAt`
- `plan_type` -> `planType`

The display model should store **used percentage** directly, matching the rest of the app's usage presentation.

## Usage Tab Integration

Add a new `OpenAIUsageView` with the same card-based layout language as the current Usage tab.

### Header

- Title: `OpenAI`
- Safari button to open the relevant OpenAI usage page
- Refresh button matching the existing Claude and Z.ai refresh control

### Content

- Optional account summary row:
  - email when decoded from `id_token`
  - plan badge from `planType` when available
- Two progress rows:
  - `Current window`
  - `Weekly usage`
- Reset countdown shown inline with each row when available
- Updated timestamp footer

Use the existing visual primitives where possible:

- `UsageCardContainer`
- `InlineUsageProgressRow`
- existing error banner treatment

OpenAI does not need a historical chart in this phase. The UI should stay intentionally smaller than the Z.ai model-usage card.

## Settings Integration

Add a new OpenAI section near the existing Z.ai settings section.

Proposed contents:

- `Enable OpenAI usage` toggle backed by `@AppStorage("openAIUsageEnabled")`
- Status badge:
  - Configured
  - Not found
  - Invalid
- Short explanatory copy clarifying that the app reads the local Codex OAuth session only for usage monitoring

Do not add:

- auth token text fields
- login buttons
- logout buttons
- API key storage

If the user enables the toggle and auth is valid, trigger a refresh. If auth is invalid, keep the toggle state and show the failure state in Settings and the Usage view.

## Usage Section Ordering

Extend the existing provider ordering logic to support three providers.

Default order:

1. Claude
2. Z.ai
3. OpenAI

Behavior:

- Providers with enabled toggles and valid displayable data may be prioritized ahead of unavailable providers
- Disabled providers must be removed from the Usage tab composition entirely
- OpenAI follows the same conditional rendering model as Z.ai, but uses its own enable flag and config state

## Menu Bar Design

Replace the single-provider percentage label with a compact multi-provider string that can show up to three items:

```text
C 42% Z 64% O 31%
```

### Visibility Rules

- Show Claude when Claude has a valid 5-hour percentage
- Show Z.ai when the Z.ai feature is enabled and a valid 5-hour percentage exists
- Show OpenAI when the OpenAI feature is enabled and a valid current-window percentage exists
- Preserve provider order as `Claude -> Z.ai -> OpenAI`
- Omit unavailable providers instead of showing placeholders
- If none are available, show only the icon as today

### Typography

Match Quotio's compact menu-label hierarchy:

- Provider letter:
  - smaller than the percentage
  - approximately `9-10pt`
  - `.semibold`
  - `.rounded` or standard secondary label styling
  - neutral/secondary foreground
- Percentage:
  - larger than the provider letter
  - approximately `11-12pt`
  - `.bold`
  - `.monospaced`
  - usage-color foreground

This makes the numeric quota value the visual anchor while keeping provider identity readable but lightweight.

### Color Logic

Adopt Quotio's "used percentage" thresholds for compact percentage text:

- `< 70% used` -> green
- `70% to < 90% used` -> yellow/orange-yellow
- `>= 90% used` -> red

This color logic applies to all three displayed providers because the menu bar is showing **used percent**, not remaining quota.

## Error Handling

OpenAI should match the app's existing Claude behavior as closely as possible:

- Missing auth file -> error message
- Unsupported auth mode -> error message
- Expired token with failed silent refresh -> error message
- `401` / `403` / non-200 response -> error message
- Decoding failure -> error message

UI behavior:

- If cached data exists, keep showing cached usage and add an error banner
- If no cached data exists, show the empty state plus the error banner
- Do not open a login flow or provide interactive remediation beyond refresh

## File Changes

| File | Change |
|------|--------|
| New `ClaudeStatistics/Models/OpenAIUsageData.swift` | OpenAI usage display and cache models |
| New `ClaudeStatistics/Services/OpenAICredentialService.swift` | Read and validate `~/.codex/auth.json` |
| New `ClaudeStatistics/Services/OpenAIUsageAPIService.swift` | Fetch, refresh, and cache OpenAI usage |
| New `ClaudeStatistics/ViewModels/OpenAIUsageViewModel.swift` | Provider-specific UI state and refresh logic |
| New `ClaudeStatistics/Views/OpenAIUsageView.swift` | OpenAI usage card for the Usage tab |
| Modify `ClaudeStatistics/App/ClaudeStatisticsApp.swift` | Create and wire the new view model |
| Modify `ClaudeStatistics/Views/MenuBarView.swift` | Render the OpenAI section in the Usage tab |
| Modify `ClaudeStatistics/Views/SettingsView.swift` | Add OpenAI feature toggle and status UI |
| Modify `ClaudeStatistics/Models/UsageFeatureSupport.swift` | Extend usage section ordering for a third provider |
| Modify `ClaudeStatistics/Models/MenuBarUsageSelection.swift` | Replace single-provider selection with compact multi-provider rendering |
| Modify `ClaudeStatistics/Resources/en.lproj/Localizable.strings` | Add OpenAI strings |
| Modify `ClaudeStatistics/Resources/zh-Hans.lproj/Localizable.strings` | Add OpenAI strings |
| Modify `scripts/usage_feature_tests.swift` | Add OpenAI ordering and menu label tests |

## Testing

Add focused tests for the new provider logic:

- Usage section ordering with Claude, Z.ai, and OpenAI combinations
- Menu bar formatting:
  - all three providers present
  - missing middle provider
  - only one provider present
  - no providers present
- Menu bar color-threshold helper behavior for used percentage
- OpenAI auth-state parsing from representative `~/.codex/auth.json` payloads
- OpenAI usage response parsing from representative `wham/usage` payloads
- Cached-data fallback behavior when fetch fails after a previous success

For manual verification:

- Use `bash scripts/run-debug.sh`
- Enable OpenAI usage in Settings
- Verify the Usage tab shows OpenAI after a successful fetch
- Verify a broken or missing auth state shows the expected error without crashing
- Verify the menu bar label updates to the compact multi-provider format

## Non-Goals

- No OpenAI API key support
- No in-app OpenAI login or logout
- No multi-account OpenAI switching
- No OpenAI historical charting in this phase
- No renaming of OpenAI's current window to "5 hours"
