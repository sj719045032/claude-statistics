# Share Role Card Implementation Plan

**Goal:** Add a role-based sharing feature that converts existing analytics into a poster card with a primary role, two secondary badges, three proof metrics, and PNG export.

**Spec:** `docs/superpowers/specs/2026-04-15-share-role-design.md`

**Architecture:** Build a new share pipeline on top of existing parsed session data:

- `ShareMetricsBuilder` derives per-period behavior metrics
- `ShareRoleEngine` maps metrics into a `ShareRoleResult`
- `ShareCardView` renders a poster
- `ShareImageExporter` exports the rendered card through `ImageRenderer`

## Task 1: Share Domain Models

**Files:**

- Create: `ClaudeStatistics/Models/ShareRole.swift`
- Create: `ClaudeStatistics/Models/ShareMetrics.swift`

- [ ] Add `ShareRoleID`, `ShareBadgeID`, `ShareProofMetric`, `ShareVisualTheme`, and `ShareRoleResult`
- [ ] Add `ShareMetrics` with the derived fields required by the role engine
- [ ] Keep the first version narrowly scoped to weekly and monthly cards

## Task 2: Share Metrics Builder

**Files:**

- Create: `ClaudeStatistics/Services/ShareMetricsBuilder.swift`
- Modify: `ClaudeStatistics/Services/SessionDataStore.swift`

- [ ] Add a builder that aggregates selected sessions and `SessionStats` into `ShareMetrics`
- [ ] Derive project count from session grouping keys
- [ ] Derive night activity from `fiveMinSlices`
- [ ] Derive peak-day and peak-5-minute metrics from existing buckets
- [ ] Derive model count and entropy from `modelBreakdown`
- [ ] Add a simple public entry point on `SessionDataStore` for `buildShareMetrics(for:period:)`

## Task 3: Role Engine

**Files:**

- Create: `ClaudeStatistics/Services/ShareRoleEngine.swift`

- [ ] Implement weighted scoring for 6 to 8 roles
- [ ] Add role guardrails and fallback role
- [ ] Implement top-2 badge selection with overlap filtering
- [ ] Implement deterministic subtitle selection so repeated exports of the same period stay stable
- [ ] Expose one function such as `makeRoleResult(from:baseline:) -> ShareRoleResult`

## Task 4: Share Card UI

**Files:**

- Create: `ClaudeStatistics/Views/ShareCardView.swift`
- Create: `ClaudeStatistics/Views/SharePreviewView.swift`

- [ ] Create a poster layout for role cards in 4:5 format
- [ ] Create a smaller square variant only if the base card is stable
- [ ] Map each role to distinct colors, icons, and background treatment
- [ ] Keep the card visually separate from the analytics UI so it feels social-first

## Task 5: Export and Share Sheet

**Files:**

- Create: `ClaudeStatistics/Utilities/ShareImageExporter.swift`

- [ ] Render `ShareCardView` through `ImageRenderer`
- [ ] Support save PNG
- [ ] Support copy image to pasteboard
- [ ] Support native macOS share sheet

## Task 6: Entry Point

**Files:**

- Modify: `ClaudeStatistics/Views/StatisticsView.swift`

- [ ] Add `Share This Period` in `PeriodDetailView`
- [ ] Limit v1 to weekly and monthly periods, or show all periods if quality is acceptable
- [ ] Open a preview sheet before export so users can confirm the role card

## Task 7: Verification

**Files:**

- Modify or add only if needed

- [ ] Build the app
- [ ] Verify export for low-data and high-data periods
- [ ] Verify localized strings do not break poster layout
- [ ] Verify role fallback works for sparse periods
- [ ] Verify different provider mixes can still generate a stable card

## Suggested Delivery Order

1. Domain models
2. Metrics builder
3. Role engine
4. Share card preview
5. PNG export
6. UI entry point

## Practical v1 Cuts

If implementation needs to stay tight, cut in this order:

1. Square layout
2. Share sheet
3. Badge diversity
4. Multi-provider special roles

Do not cut:

- proof metrics
- fallback role
- deterministic export
- clear visual differentiation per role
