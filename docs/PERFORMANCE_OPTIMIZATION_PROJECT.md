# Performance Optimization Project

> Status: plan finalized, baseline capture pending
> Scope: Claude Statistics macOS app runtime performance
> Started: 2026-05-05
> Last revised: 2026-05-05

This document is the working plan for a dedicated performance optimization
project. It turns the current static audit into a measurable optimization
program: collect traces first, fix the highest-confidence hot paths, and keep
each change tied to a before/after metric.

## Goals

1. Reduce startup CPU and IO spikes when multiple providers are enabled.
2. Keep the menu bar app responsive while sessions are scanned, parsed, and
   indexed.
3. Make large transcript workflows predictable: opening transcript, searching,
   parsing changed sessions, and rebuilding the FTS index.
4. Move expensive aggregation work off SwiftUI body paths and the main thread.
5. Reduce peak memory in large transcript parse/open/index flows.
6. Establish repeatable performance capture steps so regressions can be caught
   before release.

## Non-Goals

- Redesigning the UI.
- Changing provider behavior or cache semantics unless required for performance.
- Replacing SQLite or SwiftUI.
- Optimizing code paths without measurement unless the current implementation is
  plainly inefficient and low-risk to improve.

## Hard Constraints

The optimization plan must hold these invariants. Any PR that violates one is
a regression and gets reverted regardless of speedup.

1. **Status bar display unchanged.** Every provider currently visible in the
   menu bar must show the same icon, percentage, color, and rotation cadence
   after every PR. Empty / fallback states must trigger under the same
   conditions as today.
2. **Notch behavior unchanged.** Active session detection, idle-peek list,
   tool activity lines, approval cards, and afterglow timing all match
   today's behavior for every provider that currently emits hooks.
3. **No FTS search correctness regression.** Search results from any query
   the user could type today must remain identical or become a strict
   superset (never miss a real match).
4. **No token / cost stats drift.** Per-session and per-window token, cost,
   and model-breakdown numbers must match today's values bit-for-bit unless
   a PR is explicitly fixing a documented bug.
5. **Existing tests stay green.** `bash scripts/run-tests.sh` passes before
   and after every PR.

## Current Baseline

The first pass was not an Instruments capture. It combined code inspection,
local data-scale checks, SQLite metadata, and existing diagnostic logs.

Local data observed on 2026-05-05:

| Area | Observed Value |
| --- | ---: |
| Claude JSONL files under `~/.claude/projects` | 810 |
| Claude JSONL total size | 716.6 MB |
| Largest Claude JSONL | 32.3 MB |
| Average Claude JSONL | 906 KB |
| SQLite cache database | 104 MB |
| SQLite WAL | 764 KB |
| `session_cache` rows | 415 |
| FTS `messages` rows | 87,627 |
| Release app Memory while resident | 98.9 MB in Activity Monitor |
| Release app `vmmap` dirty resident | 100.4 MB |
| Release app physical footprint | 103.4 MB |
| Release app physical footprint peak | 484.4 MB |
| `DefaultMalloc` allocated / dirty | 57.5 MB / 74.0 MB |
| Release app `ps RSS` | 369,344 KB / ~361 MB, includes shared/mapped pages |

Largest transcript files:

| Rank | Size | Note |
| --- | ---: | --- |
| 1 | 33.9 MB | Claude project transcript |
| 2 | 31.9 MB | Claude project transcript |
| 3 | 26.2 MB | Claude project transcript |
| 4 | 24.1 MB | Claude project transcript |
| 5 | 11.3 MB | Claude project transcript |

Cached provider rows:

| Provider | Sessions | `stats_json` MB | `quick_json` MB | FTS Rows |
| --- | ---: | ---: | ---: | ---: |
| Claude | 232 | 1.5 | 0.2 | 51,837 |
| Codex | 147 | 0.5 | 0.1 | 34,536 |
| Gemini | 36 | 0.1 | 0.0 | 1,129 |

Recent diagnostic logs show startup usually initializes all three providers in
parallel and then hits cached parses:

- `Initial scan complete` appears for `claude`, `codex`, and `gemini` during
  the same startup window.
- Most recent `Full parse` entries are `0` or `1` dirty sessions, so current
  startup cost is mostly provider warmup, scanning, cache load/decode, and
  aggregation rather than full transcript parsing.

## Known Prior Work

`docs/PERFORMANCE_FIX.md` records a prior background CPU incident where the app
hit 443% CPU. Important fixes from that work are already present:

- Dirty-session processing skips full rescans on the fast path.
- Dirty events are coalesced while a batch is in flight.
- `SessionScanner.readCwd` was changed from O(N^2) repeated string decoding to
  an O(N) rolling byte-window scan.
- `SessionStats` aggregates are precomputed instead of recalculated on every
  view read.
- All-time heatmap and top-projects data are cached.

The new project should build on that work, not revisit it unless profiling
shows regression.

## Architecture Findings

Code reading on 2026-05-05 produced three boundaries that shape the rest of
the plan. Each is verified against current source — if these change, this
section must be revisited before continuing.

### Status bar is decoupled from `SessionDataStore`

`MenuBarUsageCell` (`StatusBarController.swift:361-447`) renders from
`@ObservedObject UsageViewModel`. The two published properties it reads —
`usageData: UsageData?` and `subscriptionInfo: SubscriptionInfo?` — are
populated by `UsageViewModel.loadCache()` (`UsageViewModel.swift:146-154`)
from a per-provider disk cache file. `UsageCacheWatcher` and the auto-
refresh timer keep that cache fresh independently of any
`SessionDataStore`.

**Implication:** the menu bar strip continues to work for a provider whose
`SessionDataStore` is cold, as long as that provider's `UsageViewModel`
was created and `loadCache()` was called at startup. This unblocks
Workstream B without a cache-only API rewrite.

### Notch is hook-driven for most providers

Hook-emitting providers (Claude, Gemini) feed the notch via
`NotchNotificationCenter.enqueue()` →
`ActiveSessionsTracker.record(event:)`. This pipeline does not read
`SessionDataStore.parsedStats`. Claude/Gemini stores can be cold without
breaking the notch.

`ProviderContextRegistry.bindRuntimeBridge()`
(`ProviderContextRegistry.swift:113-137`) only attaches the
`Publishers.CombineLatest3($sessions, $quickStats, $parsedStats)` →
`syncTranscriptSignals` bridge for providers whose descriptor sets
`syncsTranscriptToActiveSessions == true`. Today this is Codex.

**Implication:** Workstream B may keep Codex's store warm if the notch
is enabled, but Claude / Gemini stores can be lazy regardless of notch
state.

### `SessionDataStore.start()` cost is dominated by parse + rebucket

Lifecycle inside `start()` (`SessionDataStore.swift:63-73`) is:
file watcher → `provider.scanSessions()` → `loadAllCached()` →
quick-parse dirty → full-parse dirty → `rebucket()`. The cache load is
cheap; the dirty parse and rebucket dominate.

**Implication:** lazy-starting a store does not skip cache reads (they
are not the bottleneck) — it skips file scan + dirty parse +
aggregation. That is exactly the work Workstream B should defer for
non-selected providers.

## Performance Capture Plan

All captures should use the repository-required debug launch path:

```bash
bash scripts/run-debug.sh
```

Do not use default Xcode DerivedData for debug runs.

### Capture Scenarios

| ID | Scenario | User Flow | Tool |
| --- | --- | --- | --- |
| S1 | Cold startup | Launch app, wait until parsing indicator disappears | Instruments Time Profiler + Allocations |
| S2 | Warm startup | Relaunch with cache populated, no active CLI writes | Instruments Time Profiler |
| S3 | Active transcript append | Keep one Claude session writing transcript for 60s | Activity Monitor + `sample` + Time Profiler |
| S4 | Force rescan | Trigger provider cache rebuild / force rescan | Time Profiler + Allocations |
| S5 | Open Usage tab | Open popover, switch to Usage, toggle trend windows | Main-thread time + SwiftUI body sampling |
| S6 | Open Statistics / All Time | Open Stats, switch periods, open All Time | Time Profiler |
| S7 | Session list search | Type a 2+ char query and content-search query | Time Profiler + main-thread hang check |
| S8 | Open large Transcript | Open one large JSONL session, search inside transcript | Allocations + Time Profiler |
| S9 | Share image export | Export/copy share card | Allocations |
| S10 | Notch active state | Notch enabled, active session events flowing | Time Profiler |

### CLI Sampling Helpers

Use these when Instruments is too heavy for a quick pass:

```bash
PID=$(pgrep -f "Claude Statistics Debug" | head -1)
sample "$PID" 10 -mayDie > /tmp/claude-statistics-sample.txt
ps -o pid,%cpu,rss,utime,stime,command -p "$PID"
```

Idle CPU check:

```bash
PID=$(pgrep -f "Claude Statistics Debug" | head -1)
ps -o utime,stime -p "$PID"
sleep 60
ps -o utime,stime -p "$PID"
```

### Signpost Capture (PR1+)

PR1 wires `OSSignposter` intervals into 14 hot paths under subsystem
`com.tinystone.ClaudeStatistics`, category `performance`. The pair
below captures a warm-startup window without Instruments and prints a
duration table — repeat before / after each later PR for an apples-to-
apples comparison.

```bash
# One-shot warm startup baseline. Kills the running Debug app, relaunches
# it, waits 15s, pulls signposts via /usr/bin/log, and prints stats.
bash scripts/perf-trace-startup.sh

# Custom output path / wait time:
bash scripts/perf-trace-startup.sh /tmp/baseline-pre-pr2.log
WAIT_SECONDS=30 bash scripts/perf-trace-startup.sh
```

Under the hood:

- Writes the raw log to the chosen file (default
  `/tmp/perf-baseline-startup-<ts>.log`).
- `scripts/perf-parse-signposts.py` reads that file, pairs `begin` /
  `end` events by `(thread, name)` so concurrent same-name signposts
  on different threads do not collide, and reports count / sum / avg
  / min / max / p95 in ms per signpost.

For arbitrary scenarios (e.g. open Usage tab, search session list)
trigger the action manually after the script's `==> Launching...`
line, then rerun the parser against the same log file. For deeper
analysis (call stacks, CPU samples, allocations), capture an actual
Instruments trace with `xctrace record --template 'Time Profiler'`
or open Instruments.app and pick a template.

For a one-command before/after snapshot covering everything
headless, run:

```bash
bash scripts/perf-summary.sh
```

That wraps `perf-trace-startup.sh` (S2 signposts) and
`perf-trace-idle.sh` (steady-state CPU + RSS samples). UI-driven
scenarios (S4–S10) still need manual triggering — record a
signpost log during the action and pipe it through
`scripts/perf-parse-signposts.py`.

### Metrics to Record

| Metric | Target |
| --- | ---: |
| Idle CPU after 60s no active CLI writes | < 1% sustained |
| Idle CPU time increase over 60s | < 1s user+sys |
| Warm startup until parse indicator gone | < 2s target, < 5s max |
| Cold startup with cache populated | no visible UI hang > 100ms |
| Active transcript append CPU | < 30% sustained |
| Open large transcript | < 1s target, < 2s max |
| Session list search keystroke hang | no main-thread block > 100ms |
| Usage tab first render | no main-thread block > 100ms |
| Idle Activity Monitor Memory / dirty resident | < 120 MB target, investigate if > 180 MB |
| Peak RSS during large transcript open | record before/after, reduce if > 500 MB |
| Peak RSS during force rescan / FTS rebuild | record before/after, reduce if > 800 MB |

## Verified Hot Paths

Each hot path below was checked against current source on 2026-05-05. The
**Code path** lines cite where the issue lives. Findings that needed
correction (e.g., wording around "every provider" vs "every enabled
provider") are noted inline.

### P0: Startup Starts Every Enabled Provider

**Code path:** `ClaudeStatisticsApp.swift:369-400` (build `startupKinds`
→ `contexts.bootstrap(_:)`); `ProviderContextRegistry.swift:30-39`
(`bootstrap` creates + `start()`s one `SessionDataStore` per kind).

`AppState.init` filters `ProviderRegistry.allKnownDescriptors` by
`availableProviders(plugins:)` and calls `contexts.bootstrap(startupKinds)`,
which creates and starts one `SessionDataStore` per *enabled* provider.
Disabled / unavailable providers are excluded.

Expected cost per started store:

- One watcher.
- One scan.
- One cache load/decode.
- One initial aggregation.

Risk:

- Users pay warmup cost for providers they may not open in this session.
- Startup spikes grow linearly with enabled providers and plugin providers.

Candidate fix (refined per *Architecture Findings*):

- Selected provider: `start()` immediately.
- Menu-bar-visible providers: create + configure `UsageViewModel` and call
  `loadCache()` (cheap, disk cache), but do **not** call
  `SessionDataStore.start()` unless required by the next bullet.
- `syncsTranscriptToActiveSessions == true` providers (Codex) with notch
  enabled: `start()` immediately so the bridge can supply transcript-
  derived active-session signals.
- All others: cold until first popover tab access triggers
  `ensureContext(for:)`.
- Disabled providers: stay completely cold (no change).

### P0: Main-Thread Aggregation

**Code path:** `SessionDataStore.swift:5` (class-level `@MainActor`),
L534 `rebucket()`, L636 `rebucketAllTime()`, L720
`recomputeAllTimeAggregates()`.

`SessionDataStore.rebucket`, `rebucketAllTime`, and
`recomputeAllTimeAggregates` run on `@MainActor` and walk `parsedStats` plus
time slices.

Risk:

- UI hitches when cached stats are first loaded.
- Hitches after parse batch updates.
- Hitches when period or weekly reset boundaries change.

Candidate fix:

- Extract pure aggregate snapshot inputs.
- Compute period stats, all-time aggregates, visible stats, and model
  breakdown off-main.
- Commit the aggregate result to published properties on the main actor.
- Version the snapshot so stale background results do not overwrite newer data.

### P0: Transcript Parse and FTS Index Read Files Separately

**Code path:**
`Providers/Claude/TranscriptParser+Session.swift:17-22` (open file,
read `Data`, byte-level scan with `JSONSerialization`);
`Providers/Claude/TranscriptParser+SearchIndex.swift:7-18` (re-open
file, full `String(decoding:)`, `components(separatedBy: "\n")`,
`JSONDecoder` per line). Two callers fire independently from
`SessionViewModel`: `provider.parseSession(at:)` and
`provider.parseMessages(at:)`.

Claude full stats parsing reads the JSONL file and extracts token/stat slices.
Search indexing reads the same JSONL again, converts the full data to `String`,
splits by newline, then decodes each line with `JSONDecoder`.

Risk:

- Large dirty transcript files pay duplicate IO and duplicate JSON work.
- Full-file `String` conversion increases memory pressure.
- FTS rebuild is a large hidden cost when cache is reset.
- Peak memory can briefly hold raw `Data`, decoded `String`, split lines, decoded
  transcript entries, stats, and search messages for the same session.

Candidate fix:

- Add a combined parse result:
  `SessionParseResult(stats: SessionStats, searchMessages: [SearchIndexMessage])`.
- Let providers optionally implement a combined parser.
- For Claude, perform one Data/line scan using `JSONSerialization` or a shared
  lightweight decode path.
- Keep current separate methods as compatibility fallback for plugins.

### P1: Usage Tab Synchronous Trend Aggregation

**Code path:** `Views/UsageView.swift:349-379` `windowTrendInfo`,
L381-420 `localTrendInfo`. Called from `@ViewBuilder` at L443 and L633.

`UsageView.windowTrendInfo` and `localTrendInfo` call
`store.aggregateWindowTrendData` and `store.windowModelBreakdown` directly from
view construction. These are synchronous folds over `parsedStats`.

Risk:

- SwiftUI body recomputation can repeat expensive folds.
- Switching trend tabs or provider usage presentation can block the main
  thread.

Candidate fix:

- Move usage trend/model aggregation into `UsageViewModel` or a dedicated
  cache object.
- Compute with `.task(id:)` using a stable cache key:
  provider, parsed stats version, window range, granularity, model filter.
- Show cached or loading state while recalculating.

### P1: Session List FTS Search on Main Actor

**Code path:** `ViewModels/SessionViewModel.swift:35` (class
`@MainActor`); L74-91 `$searchText` debounce sink calls
`store.searchMessages` synchronously on `RunLoop.main`.

`SessionViewModel` debounces `searchText` and calls `store.searchMessages`
directly. SQLite FTS is usually fast, but it can block during larger queries or
writer contention.

Risk:

- Keystroke latency in the session list.
- Main-thread stalls when DB write and search overlap.

Candidate fix:

- Run FTS search off-main.
- Track a monotonically increasing search generation and discard stale results.
- Consider separate SQLite read connection for FTS queries.

### P1: Transcript View Loads and Searches Entire Session

**Code path:** `Views/TranscriptView.swift:12-13` `@State messages:
[TranscriptDisplayMessage]`; L352-353 `loadMessages()`; L357-380
`updateMatches(query:)` rebuilds a 6-field `joined(" ")` per filtered
message; L335-343 `onChange(searchText/roleFilters/toolFilters)` retriggers.

`TranscriptView` loads every display message into memory. Local search scans all
filtered messages and reconstructs searchable text on each query/filter change.

Risk:

- Large sessions cause slow open and high memory.
- Search in transcript can block UI.
- Markdown rendering and image path resolution can retain more view state than
  the raw transcript size suggests.

Candidate fix:

- Precompute `searchableText` per `TranscriptDisplayMessage` after loading.
- Debounce transcript search.
- Consider tail-first display or chunked transcript loading for very large
  files.

### P1: Full-File Data and String Copies

**Code path:** same files as the P0 parse/index split — namely
`Providers/Claude/TranscriptParser+SearchIndex.swift:7-18` (full
`String(decoding:)` + `components(separatedBy:)`); transcript display
load path through `provider.loadMessages(at:)` follows the same shape.

Several transcript paths load the whole file into `Data`, convert it to
`String`, and then split it into lines. This is convenient, but a 30 MB JSONL can
temporarily become several multiples of its on-disk size.

Risk:

- Memory spikes during parse, FTS indexing, transcript display, and search.
- Higher allocator pressure increases UI hitch risk even when CPU is acceptable.

Candidate fix:

- Prefer streaming or chunked line readers for parse/index/display paths.
- Avoid converting the entire file to `String` when only line-local JSON is
  needed.
- Avoid storing both raw text and stripped/searchable text unless the latter is
  worth the memory tradeoff and bounded.

### P2: Per-Session SQLite Transactions

**Code path:** `Services/DatabaseService.swift:380-461`
`saveSessionStatsAndIndex` — `BEGIN TRANSACTION` at L396, `COMMIT` at
L461; upsert / FTS delete / FTS insert statements are prepared and
finalized inside the same call (L412/L426/L438), no statement reuse.

`DatabaseService.saveSessionStatsAndIndex` opens one transaction per session.
During full or forced rebuild, each session repeats statement preparation and
commit.

Risk:

- Slow forced rescan / rebuild.
- Extra fsync and lock churn despite WAL.

Candidate fix:

- Add `saveSessionsStatsAndIndexes` batch API.
- One transaction per parse batch.
- Reuse prepared statements for cache upsert, FTS delete, and FTS insert.

### P2: Menu Bar Usage Strip Recompute

**Code path:** `App/StatusBarController.swift:258`
`rotationInterval = 3`; L281 `Timer.publish(every:on:.main)` increments
`tick`; L307-323 `visibleKinds`/`renderableKinds` re-evaluate from
`ProviderRegistry` + `MenuBarPreferences` on each render.

Note (corrected): the 3-second tick itself is **rotation only** — it
does not pull fresh data. Data stays fresh via `UsageCacheWatcher` +
auto-refresh on each `UsageViewModel`. The recompute risk is purely the
SwiftUI body re-evaluation cost when the kind lists are derived rather
than memoized.

Risk:

- Low risk today with three providers.
- Could matter with many plugin providers.

Candidate fix:

- Cache visible provider kinds in `AppState`.
- Update only on plugin lifecycle and menu-bar preference changes.

### P2: Share Image Export on Main Actor

**Code path:** `Utilities/ShareImageExporter.swift:13-44`
(`@MainActor static func render`): `ImageRenderer` →
`tiffRepresentation` → `NSBitmapImageRep .png` →
`temporaryDirectory.write`.

`ShareImageExporter.render` uses SwiftUI `ImageRenderer`, TIFF conversion, PNG
encoding, and temp-file write on the main actor.

Risk:

- Export is user-initiated and acceptable, but large batch exports can block UI.

Candidate fix:

- Keep SwiftUI rendering on main actor.
- Move PNG encoding/file writing off-main if batch export becomes expensive.

### P2: Resident Heap Trimming

**Code path (likely contributors, to confirm with Allocations):**
`SessionDataStore.swift` (per warm provider — `sessions`, `quickStats`,
`parsedStats`, period stats, all-time caches);
`ViewModels/SessionViewModel.swift` (`recentSessions`,
`filteredSessions`, `projectGroups` derived lists);
`Views/UsageView.swift` + `Views/TranscriptView.swift` SwiftUI state;
`UsageViewModel` secondaries via `UsageVMRegistry`.

Current resident memory is acceptable, but `DefaultMalloc` is the main private
heap bucket: about 57.5 MB allocated and 74.0 MB dirty in the release process
sampled on 2026-05-05. The big WebKit and framework regions inflate RSS, but
their dirty memory is small and should not be treated as app-owned resident
memory.

Likely resident contributors:

- One `SessionDataStore` per warm provider, each holding `sessions`,
  `quickStats`, `parsedStats`, period stats, all-time caches, and heatmap/top
  project caches.
- `SessionViewModel` derived lists (`recentSessions`, `filteredSessions`,
  `projectGroups`) duplicate `Session` values for display convenience.
- SwiftUI / AttributeGraph state for the menu bar strip, popover, settings,
  notch window, and Markdown views.
- `UsageViewModel` secondaries and cache watchers for non-selected providers.

Candidate fix:

- Measure heap object classes with Instruments Allocations before trimming.
- Lazy-start or cold-stop non-selected provider stores when they are not needed
  for menu bar or notch.
- Store project group membership by session id/index instead of copying full
  `Session` values if Allocations shows this is material.
- Release transcript `messages` and selected detail/trend caches on view
  disappearance where restoring state is not required.
- Avoid adding permanent caches unless they replace more expensive repeated
  allocations.

## Proposed Workstreams

### Workstream A: Measurement Harness

Deliverables:

- Add scoped timing logs around startup, scan, cache load, rebucket, all-time
  aggregate, parse stats, parse search index, DB save, usage trend aggregation,
  FTS search, transcript load, and transcript search.
- Add a developer-only performance checklist in this document.
- Capture baseline Instruments traces for S1-S8.

Implementation notes:

- Prefer a tiny `PerformanceTracer` utility with signpost support.
- Keep logs gated or low-volume so tracing itself does not become noise.
- Use `os_signpost` where possible so Instruments can correlate phases.

### Workstream B: Startup and Provider Warmup

Deliverables:

- Decouple `UsageViewModel` lifecycle from `SessionDataStore` lifecycle:
  every menu-bar-visible provider gets a configured `UsageViewModel` with
  `loadCache()` called at app start, regardless of whether its store is hot.
- Selected provider: `SessionDataStore.start()` synchronously at boot.
- `syncsTranscriptToActiveSessions == true` provider with notch enabled
  (today: Codex): `start()` synchronously at boot.
- Other enabled providers: store cold; first popover access triggers
  `ensureContext(for:)` which calls `start()` and shows a parse indicator
  in the affected tab(s).
- Startup metrics before/after (S1 cold, S2 warm, multiple providers
  enabled).

Validation:

- Menu bar strip behaviour diff is empty for every visible provider —
  same cells, same percentages, same colors, same rotation.
- Notch shows the same active sessions and tool activity as today for
  Claude / Gemini / Codex with notch enabled.
- Switching to a previously cold provider tab starts its store and shows
  progress without freezing the popover.
- Disabled providers create no watchers, no `UsageViewModel`, no
  `SessionDataStore`.

### Workstream C: Parser and Index Pipeline

Deliverables:

- Combined parse/index path for Claude.
- Compatibility fallback for plugin providers.
- Unit tests covering stats and FTS messages for representative JSONL lines.

Validation:

- Full parse numbers stay stable.
- FTS search results remain available.
- Forced rebuild reads large transcript files once per parse pipeline.

### Workstream D: Aggregation Off Main Thread

Deliverables:

- Off-main period/all-time aggregate builder.
- Versioning to prevent stale aggregate writes.
- Usage trend and window model breakdown computed asynchronously.

Validation:

- Stats/Usage UI remains visually identical.
- Main thread no longer shows aggregate folds as a top sample during tab open.

### Workstream E: Search and Transcript Responsiveness

Deliverables:

- Async FTS search in session list.
- Transcript searchable text precomputation and debounced search.
- Optional chunking strategy for very large transcript files.
- Memory profile for opening the top 3 largest transcripts.

Validation:

- Typing in search fields does not produce >100ms main-thread stalls.
- Transcript search results remain accurate.
- Peak RSS stays within the project target.

### Workstream F: Database Batch Writes

Deliverables:

- Batch DB save API.
- Parse batch uses one transaction for multiple session results.
- Statement reuse for FTS insert loops.

Validation:

- Forced rescan / cache rebuild time improves.
- Existing cache migration and delete flows keep working.

### Workstream G: Memory Peak Reduction

Deliverables:

- Allocation trace for startup, force rescan, and opening the largest transcript.
- Replace full-file `String` split paths where profiling confirms large
  temporary allocations.
- Bound transcript display/search memory for large sessions.

Validation:

- Peak RSS during large transcript open and force rescan is recorded before and
  after.
- No new UI latency regressions from streaming/chunking changes.

## Final Implementation Order

The plan ships as 7 PRs ordered by risk + dependency. Each PR is
independent enough to land on its own and each carries before/after
numbers. Re-evaluate the order after PR1 lands — once `os_signpost`
data exists, later PRs can be reprioritized to chase the actual top
samples.

### PR1 — Measurement + safe quick wins

- **A (light):** `PerformanceTracer` with `os_signpost` + scoped
  timing around: `AppState.init`, `bootstrap`, `SessionDataStore.start`,
  `initialLoad`, `rebucket`, `rebucketAllTime`,
  `recomputeAllTimeAggregates`, `parseSession`, `parseMessages`,
  `saveSessionStatsAndIndex`, `searchMessages`,
  `UsageView.windowTrendInfo` + `localTrendInfo`,
  `TranscriptView.loadMessages` + `updateMatches`.
- **E2:** `TranscriptDisplayMessage.searchableText` precomputed once at
  load; `TranscriptView.updateMatches` reads the field instead of joining
  six fields per keystroke.
- **E1:** `store.searchMessages` becomes `async`; `SessionViewModel`
  search sink wraps the call in a `Task` keyed by a monotonically
  increasing search generation token; only the latest token's result
  writes to `searchSnippets`.

Touches no provider lifecycle, no aggregation rewrite, no parser
changes. Status bar and notch are untouched.

### PR2 — Provider startup staging (Workstream B)

Lands the lazy-store design with the explicit invariants in
*Hard Constraints* and the deliverables in *Workstream B*.

### PR3 — Off-main `SessionDataStore` aggregation (Workstream D, part 1)

Move `rebucket`, `rebucketAllTime`, `recomputeAllTimeAggregates` off
`@MainActor`. Pure-input snapshot in, background-actor compute, main-
actor commit gated by a snapshot version so stale results never
overwrite newer state.

### PR4 — Async Usage trend / model breakdown (Workstream D, part 2)

`UsageView.windowTrendInfo` / `localTrendInfo` move into
`UsageViewModel` (or a dedicated cache object) and run via
`.task(id:)` keyed by (provider, parsed-stats version, range,
granularity, model filter).

### PR5 — Database batch writes (Workstream F)

New `saveSessionsStatsAndIndexes` batch API; one transaction per parse
batch; reused prepared statements for cache upsert / FTS delete / FTS
insert.

### PR6 — Combined Claude parse/index path (Workstream C, requires SDK bump)

Add `SessionParseResult` to the SDK (ABI-additive — follow
`scripts/sdk-mode.sh published` flow + `sdk-v<x.y.z>` release). Claude
provider switches to single-pass parse + FTS extract; plugin providers
fall back to the existing pair of methods.

This is the riskiest PR and lands last for a reason — must come after
PR1 (signposts make any regression visible) and PR3 (aggregation already
off-main so any parse-side regression does not cascade into UI hitches).

### PR7 — Large transcript chunking + memory peaks (Workstream E3 + G)

Conditional on PR1 traces. Likely shape: tail-first transcript display,
lazy chunk loading by scroll position, and replacing remaining full-file
`String` paths in display/search where Allocations confirms peak
contribution. Memory targets are checked against the metrics table in
*Performance Capture Plan*.

## First PR Scope

PR1 is concrete enough to start now without further design. Three
artifacts, all independent:

1. **`PerformanceTracer` utility** at `ClaudeStatistics/Utilities/`:
   - One signpost name per call site listed in PR1 above.
   - `measure(_:_:)` overload that wraps a closure and emits begin/end
     signposts.
   - Quiet `OSLog` category so release builds carry no measurable cost.

2. **Transcript searchable-text precompute:**
   - Add `searchableText: String` to `TranscriptDisplayMessage`.
   - Compute it once when messages are loaded
     (`TranscriptView.loadMessages` → `viewModel.loadMessages(for:)`).
   - `TranscriptView.updateMatches` reads `msg.searchableText` directly
     instead of rebuilding the 6-field `joined(" ")` per call.

3. **Async FTS search:**
   - `DatabaseService.search(query:provider:)` exposed via an `async`
     wrapper (or moved to a background queue).
   - `SessionViewModel.$searchText` debounce sink wraps the call in a
     `Task` and tags it with `searchGeneration: UInt64` (incremented per
     keystroke). Only the latest token's result writes to
     `searchSnippets`.

PR1 acceptance:

- `bash scripts/run-tests.sh` green.
- `bash scripts/run-debug.sh` launches; manual smoke: open transcript,
  type in transcript search, type in session list search, no visible
  hitches.
- Instruments S5 / S7 / S8 captured once for baseline (kept locally or
  attached to the PR description).

## Acceptance Checklist

Before declaring the project complete:

- [ ] Baseline traces are saved or summarized for S1-S8.
- [ ] Every implemented workstream has before/after numbers.
- [ ] `bash scripts/run-debug.sh` passes.
- [ ] Existing test suite passes.
- [ ] Idle CPU stays below target.
- [ ] Startup no longer initializes unnecessary provider stores immediately.
- [ ] Usage and Stats tabs do not perform large synchronous folds in SwiftUI
      body paths.
- [ ] Large transcript open/search has measured latency and memory bounds.
- [ ] FTS search remains correct after any parser/index changes.

## Open Questions

1. ~~Should menu-bar usage for non-selected providers require full session
   stores, or can it rely only on usage APIs/cache?~~  
   **Resolved 2026-05-05:** the menu bar reads `UsageViewModel.usageData`
   from a separate disk cache (see *Architecture Findings*); no
   `SessionDataStore` is required.
2. ~~Should all provider stores stay warm when Notch is enabled, or can
   Notch restore active sessions without full historical scans?~~  
   **Resolved 2026-05-05:** hook-driven providers (Claude, Gemini) need
   no store warm for the notch. Only providers with
   `syncsTranscriptToActiveSessions == true` (today: Codex) require the
   store warm when notch is enabled.
3. How much plugin-provider compatibility must the combined parser/index
   path expose in the SDK? *(blocks PR6)*
4. Should SQLite use separate read/write connections to reduce FTS search
   contention? *(revisit after PR5)*
5. What is the largest transcript size we want to officially support
   without degraded UI? *(revisit after PR1 baseline + PR7 sizing)*

## Notes for Future Changes

- Keep each optimization behind a clear metric.
- Avoid broad refactors mixed with performance changes.
- Preserve provider-specific parsing behavior inside provider modules.
- If a change modifies stats or FTS output, add focused tests before tuning.
- Do not regress the prior fixes documented in `docs/PERFORMANCE_FIX.md`.
