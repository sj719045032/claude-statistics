# Cross-provider performance optimization handoff

Last updated: 2026-09-10, local workspace state. This document is a handoff
record, not a claim that the optimization objective is complete.

## Goal

Resolve the sustained-CPU/memory risk reported in GitHub issue #18 across the
host and **all providers**: builtin Claude/Cowork plus catalog Codex, Gemini,
and compatibility behavior for other/older plugins. The issue reports about
110% average CPU on an M3 16 GB Mac, but does not include a provider, workload,
or trace, so no single root cause has been proven.

The authoritative checklist is [PERFORMANCE_V2_EXECUTION.md](PERFORMANCE_V2_EXECUTION.md).
Every requirement in that checklist remains unchecked until it has matching
runtime evidence; green unit tests alone do not complete the goal.

## Repository state

Main repository started from `main` at `4c0e3f7` (3.5.11). It is deliberately
dirty with the optimization work. Do not discard or reset these changes.

The catalog repository at `build/catalog-repo` is a separate Git repository and
is also deliberately dirty:

- modified: `Sources/CodexPlugin/CodexProvider.swift`,
  `Sources/CodexPlugin/CodexTranscriptParser.swift`,
  `Sources/GeminiPlugin/GeminiProvider.swift`,
  `Sources/GeminiPlugin/GeminiSessionScanner.swift`,
  `Sources/GeminiPlugin/GeminiTranscriptParser.swift`
- new: `Sources/GeminiPlugin/GeminiCheckpointParser.swift`, `Tests/`,
  `scripts/run-parser-tests.sh`

No release, commit, push, SDK publication, or user-plugin replacement has been
performed as part of this work.

Read `CLAUDE.md` before building, testing, releasing an SDK, or publishing a
catalog plugin. In particular:

- Run host tests only with `bash scripts/run-tests.sh`.
- Run the debug app only with `bash scripts/run-debug.sh`; it uses
  `/tmp/claude-stats-build` and the debug bundle ID.
- Never manually edit the SDK mode blocks. `scripts/sdk-mode.sh` owns them.
- Do not run catalog `dev-install.sh` blindly: it mutates the user's shared
  plugin directory, while the installed release app still uses the published
  SDK.

## Verified evidence so far

### Baseline

- Baseline suite: **798 tests passed** at 2026-09-10 09:22:12.
- Local cached data at baseline: 233 Claude, 722 Codex, 30 Gemini sessions;
  largest cached logs were about 118 MB (Claude) and 869 MB (Codex).
- Read-only sampling of installed 3.5.11 did not reproduce sustained 110% CPU.
  It observed approximately 1.8 GB physical footprint and a 5.4 GB lifetime
  peak. This is not an equivalent workload benchmark.

### Current test/build evidence

- `bash scripts/run-tests.sh`: **904 tests, 1 skipped, 0 failures**. The skip is
  `TranscriptPagingRealDataTests`, which runs under
  `TEST_RUNNER_CLAUDE_STATS_REAL_DATA=1` and passes against real transcripts.
  Log: `/tmp/claude-stats-build/xcodebuild-test.log`.
- The `SessionDataStore` scheduler routing that the previous pass left
  unverified compiled and passed (885 tests at that point).
- Catalog parser harness: actual Codex/Gemini source compiled against the local
  SDK, **22 tests, 0 failures**. Re-run with
  `cd build/catalog-repo && bash scripts/run-parser-tests.sh` after touching
  SDK or catalog code.
- Required debug build rebuilt, installed and launched via
  `bash scripts/run-debug.sh`. It runs the fixed SDK, but the user's installed
  Codex plugin bundle is still the old binary, so it is not proof of new-plugin
  runtime behavior.

### Parser measurements (isolated, not whole-app acceptance)

All measurements are equivalent-work parser processes, not rendered-app or
continuous-writer measurements:

| Provider/input | Legacy | Checkpointed | Correctness |
| --- | --- | --- | --- |
| Codex, 93,476,920-byte real log | 3.349–3.375 s, 687.7–706.3 MB peak | 1.131–1.143 s, 307.3–308.7 MB peak | tokens and 4,877 index rows match |
| Gemini, 685,245-byte snapshot | 48.4–49.0 ms, 13.0–13.7 MB peak | 32.8–34.9 ms, 11.1–11.3 MB peak | tokens and 103 index rows match |

Logs are `/tmp/codex-measure-{legacy,checkpoint}-{1,2,3}.log` and
`/tmp/gemini-measure-{legacy,checkpoint}-{1,2,3}.log`.

Additional real-data comparison checked 22 Gemini files and four Codex files
(largest 93,476,920 bytes) against legacy statistics and search content. Logs:
`/tmp/gemini-checkpoint-real-data.log` and `/tmp/codex-checkpoint-real-data.log`.

## Implemented architecture

### Shared SDK and host pipeline

New SDK files under `Plugins/Sources/ClaudeStatisticsKit/` provide:

- `TranscriptFileReader`: fixed-size chunk reads from a real byte offset,
  split UTF-8/JSONL record handling, partial-tail preservation, and exact file
  identity snapshots (device, inode, nanosecond mtime, size).
- `TranscriptFileContinuity`: bounded head/tail samples for append validation.
  This detects common truncate/regrow cases, **not arbitrary edits in the
  middle** of an old append-only log.
- `CheckpointedJSONLReader` and `CheckpointedSessionDataProvider`: optional,
  backward-compatible provider capability with durable parser state, source
  checkpoints, identified FTS updates, and byte-read reporting.
- `JSONMetadataReader`, `TranscriptTimestampParser`, and signed day-slice
  delta support.

`DatabaseService` now stores parser checkpoints and index-complete state and
writes the statistics, fingerprint, checkpoint, quick preview, and FTS change
in one SQLite transaction. A checkpoint UUID compare-and-swap rejects stale
updates. Index changes distinguish `.preserve`, full replacement, identified
replacement, and identified upsert/removal.

`BackgroundWorkScheduler` is a global actor with two concurrent reservations
and a 128 MiB estimated byte budget. Oversized work runs alone; interactive
requests win within a priority class; queued cancellation removes waiters. The
latest change also checks cancellation **after** a non-cooperative operation
returns so its result cannot be committed/published.

`LatestSnapshotWorker` is used for latest-only background aggregate/trend work.
It retains one active request plus the newest pending request and fences stale
results at publication.

### Claude and Cowork

`ClaudeCheckpointParser` is wired through `ClaudeProvider`:

- root and each child/subagent JSONL retain independent cursors;
- usage/message IDs deduplicate with main transcript precedence;
- revisions retract old contributions before applying the new ones;
- child deletion removes its contribution; root replacement keeps unchanged
  children; missing child model inherits the root model;
- standard and Cowork watcher paths map child changes/deletions back to the
  root session, including `/var` vs `/private/var` normalization.

Fixture coverage includes byte-sized arbitrary batches, split UTF-8, partial
EOF records, no-final-newline records, restart state, revisions, tool dedup,
child append/deletion, root replacement, and model attribution. A sparse 1 GiB
reader fixture verifies that appending 18 bytes reads 18 bytes (plus bounded
continuity samples only when relevant).

### Codex and Gemini catalog plugins

Both catalog providers conform to the optional checkpoint capability.

- Gemini: metadata-only session scanning with exact snapshot cache; JSONL
  message replacement retracts old contributions/index rows; snapshots decode
  only when changed; known appends avoid a full rescan.
- Codex: checkpoint state keeps cumulative root usage; child sessions wait for
  `NEW_TASK` and exclude inherited parent content; stable tool-result IDs allow
  index updates; hierarchy/visibility semantics are preserved.

Known remaining Codex issue: its thread metadata scanner still queries all
thread rows and stats rollout files on relevant database/WAL changes. It needs
a durable metadata fingerprint/change feed so title/archival updates do not
become repeated full scans.

### Aggregate, usage, and maintenance work

- `IncrementalSessionAggregator` retracts/replaces only changed raw
  contributions. It carries per-session/day/project/model membership and
  reuses unchanged historical slices. Pricing/timezone/calendar invalidation
  recomputes projections without reparsing transcripts.
- `UsageTrendViewModel` puts trend/model folds off the view rendering path,
  coalesces requests, retains at most eight entries / about 2 MiB estimated
  cache, and bounds cumulative chart samples at 1,200 points.
- `UsageViewModel` coalesces automatic/manual refresh requests, fences old
  accounts/providers, retries credential refresh, and backs off failure/429.
- Index repair processes one session at a time and commits/releases its index
  before parsing the next. Archive tasks now share the scheduler and release
  per-file autoreleased buffers.
- The current in-progress `SessionDataStore` change makes initial/dirty
  parsing one complete session transaction at a time. This deliberately trades
  cold-start parallelism for bounded retained FTS result memory. It also makes
  old plugins use their existing combined stats+search parser instead of first
  reading a whole file only to attempt the obsolete stats-only incremental API.
  Old plugins still have an inherently whole-file parser; the host can bound
  their concurrency and reject stale results, not make their implementation
  streaming.

## Session of 2026-09-10 (second pass)

### Verified the previous session's open items

- `bash scripts/run-tests.sh`: the late `SessionDataStore` scheduler routing
  changes compiled and passed — **885 tests, 0 failures**. That closes the
  previous handoff's "needs immediate verification" list item 1.
- `git diff --check` clean in both repositories.
- `cd build/catalog-repo && bash scripts/run-parser-tests.sh`: 16 tests passed.

### Bounded transcript detail (outstanding item 1) — done for Claude/Cowork

New optional SDK capability `PagedTranscriptProvider`: `loadTranscriptOutline`
streams the session once and returns one bounded row descriptor per display row
(id, role, tool name, timestamp, source byte ranges); `loadTranscriptPage`
rebuilds only the requested rows from only those bytes. Claude's parser was
refactored so the whole-file parse, the outline pass and page materialization
share one record→row mapping and one cross-record linker, so a page is the row
the whole-file parse would have produced. Host `TranscriptPagingModel` owns an
LRU window (12 pages / 8 MiB, injectable) and runs transcript search off the main
actor over the full history in batches, debounced and cancellable; the
per-message search-text cache is gone. Non-paged providers keep their whole-file
parse behind the same model.

Measured on the largest local Claude transcript (107,262,069 bytes, 11,742 rows):
one screenful cites 70,527 bytes; retained outline 1,444,262 bytes versus
5,076,267 bytes of row bodies; and the old per-keystroke main-thread search scan
measured **0.714 s**, which is now off the main actor. Open latency is unchanged
(the outline still decodes every record) — no improvement is claimed there.

Two pre-existing defects surfaced. The nondeterministic tool summary
(`Dictionary` iteration order) was **fixed**, because paging requires two decodes
of one record to agree. Edit rows losing `editOldString`/`editNewString` when a
tool result is attached is **not fixed** — it is display behavior outside this
task; both paths reproduce it and a test pins it.

### Chunked reads were never bounded — highest-impact finding

`TranscriptFileReader`, which every checkpoint parser sits on, peaked at 944 MB
while reading an 869 MB rollout and retaining nothing:
`FileHandle.read(upToCount:)` returns autoreleased `NSData`, so without a pool
per chunk the whole file stays alive until the parse returns. Fixed there and in
`JSONMetadataReader` / `TranscriptRecordReader`, plus the decode sites that hand
back autoreleased Foundation trees (`CheckpointedJSONLReader`, Codex's record
stream and checkpoint loop, Gemini's two JSONL line loops).

On the 869 MB rollout, peak physical footprint: reader-only 944 MB → 61 MB;
reader + decode 1,067 MB → 137 MB; **Codex checkpoint parse 1,983 MB → 160 MB**;
**Codex `parseMessages` 3,448 MB → 167 MB**. Token totals, index rows and the
transcript-row digest are unchanged over 20 real rollouts plus the 869 MB one.

`CodexTranscriptParser.readEvents` also became a streaming `AnySequence<Event>`
instead of materializing the whole file four times over; `readEventScope` keeps
its forked-subagent semantics from a bounded head plus a buffer of the events
since the last `task_started`.

### Same defect on the Claude side, and a hole it exposed

Auditing the host for the same pattern found it everywhere a record is decoded
or a row extracted. Bytes still live when the call returns, on the 107 MB
transcript: `parseSession` 130,516,688 → 104,080; `parseMessages` 293,791,280 →
~0; `loadTranscriptOutline` 293,818,432 → 3,440. The outline number was a defect
in the paging work itself — the pass whose whole point is to hold row identity
instead of row bodies was holding 293 MB of bridged Foundation objects.

Synthetic fixtures did not reproduce it; only real transcripts did. The
assertions therefore live in the gated real-data test. A synthetic test that
passes with the fix removed is worse than none, so one was written, found
vacuous, and deleted rather than kept.

Chasing an unused `TranscriptOutline.matchesSources()` also surfaced a real
hole: a transcript replaced while its view is open keeps the old byte offsets in
range, so a page read from it parses fine and is wrong. The model now verifies
source snapshots before committing a page or a search batch and rebuilds the
outline when they no longer match, with a test.

### Current test/build state

- Host: **926 tests, 3 skipped, 0 failures** (`bash scripts/run-tests.sh`). The
  skip is the real-data comparison, which passes when enabled.
- Real-data (`TEST_RUNNER_CLAUDE_STATS_REAL_DATA=1 bash scripts/run-tests.sh`):
  the eight largest local Claude transcripts rebuild every row page by page and
  match the whole-file parse field for field. Measurements in
  `/tmp/claude-503-paging-realdata.txt`.
- Catalog: **31 tests, 0 failures** (`bash scripts/run-parser-tests.sh`);
  `--compare codex` 20/20, `--compare gemini` 29/29 real transcripts.
- SDK xcframework rebuilt (`bash scripts/build-xcframework.sh`). Catalog plugin
  bundles were **not** rebuilt or installed; the user's installed Codex plugin is
  still the old binary.
- `bash scripts/run-debug.sh` built, installed and launched the debug app.

### Still open from this pass

- Codex and Gemini have not adopted `PagedTranscriptProvider`; their transcript
  detail is still a whole-file parse (now bounded in peak, but every row is
  still materialized and retained).
- Codex `parseTrendData` and `parseSearchIndexMessages` stream now but still
  build whole result arrays.
- The remaining outstanding items 2–8 below are untouched by this pass.

## Session of 2026-09-11 (third pass) — outstanding items 1–8

Current state (supersedes the counts above): host **950 tests, 8 skipped
(gated real-data/acceptance), 0 failures**; catalog **39 tests, 0 failures**;
`git diff --check` clean in both repositories. Nothing committed. Details and
numbers for every item are in `PERFORMANCE_V2_EXECUTION.md`.

1. **Paging — done.** Codex and Gemini JSONL adopt `PagedTranscriptProvider`;
   `TranscriptOutlineEntry.token` carries Codex's event index for images.
   Real files: Codex 20/20 page-for-page equal to the whole parse; Gemini JSON
   snapshots fall back to the whole parse.
2. **Maintenance memory — done.** Segmented archive (v14) plus schema v15
   moving pre-v14 blobs to `transcript_legacy_blobs`; the real database
   relocated 722 Codex and 234 Claude archives in the background (Gemini's 30
   wait for its plugin). Archived transcripts are now streamed to a temporary
   file a piece at a time and paged by the session's own provider (they used
   to be decompressed whole and decoded with Claude's parser). All 987 real
   archives, up to 869 MB, stream with 12 MB of peak-footprint growth.
3. **Codex metadata — done.** Consumed-column digest (2.8 ms), decided off
   the main actor. Per-row deltas measured and declined: the full scan they
   would replace costs 7.9 ms for 668 sessions.
4. **Runtime integration — done for Codex via a debug-only route.**
   `DEBUG_BUNDLED_PLUGINS` bundles a built `.csplugin` into the debug app; the
   loader refuses the installed duplicate before `dlopen`. Cold peak 1.9–2.0 GB
   → 214.8 MB. Nothing in the shared plugin directory was replaced.
5. **Scheduler — done.** The four `Task.detached` parses in `SessionViewModel`
   now go through the scheduler with cancellation.
6. **Notch — done.** Publish/persist only on change; idle repair skips
   unchanged transcripts; task scans stream, and now resume from their offset
   with carried task state (`RuntimeSession.taskScanTasks`) instead of
   rereading the whole transcript on every hook event of a session without
   displayed tasks — the cause of the periodic idle spikes. On a 107 MB
   transcript one scan costs 607.1 ms from byte 0 and 0.10 ms resumed.
7. **Acceptance — measured; all gates met.** 1 GiB append reads
   12,294 bytes; CPU per append, after a compact binary checkpoint state and a
   checkpoint container without base64, 249 ms at 131k messages (was 1,023.7)
   and 55 ms on a real 24k-message session (was 122) — still proportional to
   the state. Sustained appends 23.6% (was 31.5%; gate 30%); stalls ≤ 7.9 ms.
   Idle, after the task-scan and `memchr` fixes, on
   a quiet machine: **1.14%** over five minutes against < 1% — a flat floor,
   the earlier 0.3–1 s spikes gone. Defaults observers now act only on
   change, and TelemetryDeck's session stats are off
   (`config.sessionStatsEnabled = false`, one line in
   `ClaudeStatisticsApp.swift`): final idle **0.750%** on a quiet machine.
   That line drops TelemetryDeck's retention metrics; the owner confirmed it
   (without it idle is ~1.07%). Re-measured after 4 h of uptime while two
   other agent sessions wrote: 1.27–1.45%, not an idle figure. Footprint grew
   53.8 → 93.3 MB over those hours (peak 117.4 MB) — not yet investigated.
   The byte-wise newline search is now `memchr` (869 MB scan 2.3 s → 0.2 s).
8. **Rendered UI — done for Claude and Codex** via `#if DEBUG` launch
   switches and window-only captures. Gemini runtime verified with the plugin
   bundled and enabled only for the debug build
   (`CLAUDE_STATISTICS_DEBUG_DISABLED_PLUGINS`): 30 sessions parsed, 21
   checkpoints, 30/30 inline archives moved; the user's setting untouched.

**Do not install the new plugins into the shared plugin directory or publish
them before a host release:** they import ~80 SDK symbols the 3.5.11 app does
not export (checked with `nm`), so the release app would lose Codex/Gemini.

Remaining work is listed under "Remaining work" in the execution log. The
"Recent changes" and "Outstanding work" sections below are the second pass's
text, kept for history.

**Screenshots:** only window-only captures of the debug app (`screencapture
-l <windowID>`); full-screen captures record unrelated personal content.

## Recent changes that need immediate verification

These are the highest priority before any new feature work:

1. Run `bash scripts/run-tests.sh`. The late scheduler routing changes in
   `SessionDataStore` were made after the last green run.
2. Run `git diff --check` in both repositories.
3. Inspect the new failure behavior carefully: legacy parser output is guarded
   by a before/after `TranscriptFileSnapshot`. If a file changes while an old
   parser reads it, nothing is committed; the store marks it for retry.
4. Check the test suite's new cases in `SessionStoreLifecycleTests`:
   startup releases one index before the next parse, legacy append refreshes
   FTS through the actual watcher path, replacement rejects a mixed parse, and
   cancelling a non-cooperative legacy parser cannot commit its late result.
5. Ensure the `SessionDataStore` comments accurately describe the final
   behavior after the test run; some old `PR5` comments were removed/reworked
   during the one-session commit conversion.

## Outstanding work, in recommended order

1. **Make transcript detail bounded.** Done for Claude/Cowork and for the host
   shell (see the 2026-09-10 second-pass section). Remaining: have the Codex and
   Gemini catalog plugins adopt `PagedTranscriptProvider` so their transcript
   detail stops materializing every row — Codex has by far the largest local
   transcripts. `TranscriptOutlineEntry` has no provider-owned token field yet;
   Codex needs one because its image cache names files by the event's index
   within the scope.
2. **Finish whole-file maintenance memory work.** Archive writes are done:
   segmented, incremental, v14 schema, measured on the 869 MB rollout (full
   pass 1,400 MB → 29.5 MB peak; a pass after a 1.4 MB append 0.05 s instead
   of a full rewrite). See "Segmented transcript archive" in the execution log.
   Still whole: reading an archived transcript, and old plugins'
   `parseSessionAndSearchIndex` results, which the host cannot make stream.
   The real `data.db` is on v14; a verified backup is in
   `~/Library/Application Support/ClaudeStatistics/backups/`. **`run-tests.sh`
   opens the real shared database** — that is how it reached v14 before any app
   carried the code. Treat every host test run as touching user data until the
   test host is isolated. No real-app archive pass has run yet: the first one is
   the hourly pass for a Codex session that has changed since launch.
3. **Finish Codex metadata separation.** Done as a rescan gate: the Codex
   scanner digests only the thread columns a scan consumes, and the host asks
   `shouldRescanSessions` off the main actor. Per-turn Codex commits no longer
   rebuild the session list. Digest 2.7 ms on the real database. Still open:
   per-row deltas for the rare relevant changes, and installing the catalog
   build. See "Codex thread-metadata separation" in the execution log.
   Measuring what the gate saves surfaced the bigger problem: pre-v14 archive
   blobs inside `session_cache` rows made every read or update of a later
   column walk the blob (1.06 s per read for the 526 MB one), on every parse
   and every forced rescan (2.8 s and 1.9 GB of WAL per Codex rescan). Schema
   v15 moves them to `transcript_legacy_blobs` in the background: on a clone the
   forced rescan's metadata write drops from 2,773 ms to 5.7 ms. 3.5.11 cannot
   read moved archives and re-inlines them when it runs. See "Moving pre-v14
   archives out of session_cache rows" in the execution log.
4. **Validate provider runtime integration.** Rebuild the SDK and catalog
   bundles in local mode, then use an isolated/debug-safe loading route. Do not
   overwrite the user's installed plugins without explicit authorization.
   Verify actual Claude, Codex, and Gemini watcher/update paths, including a
   continuously written large transcript.
5. **Close remaining scheduler gaps.** Audit every scan, parser, index repair,
   archive, full-history search, and derive path. The scheduler's byte figure
   is an admission estimate, not a hard process-memory limit. Add cancellation
   checks after non-cooperative work at every commit boundary.
6. **Notch and inactive UI.** Profile `ActiveSessionsTracker` (15 s refresh,
   2 s liveness scan, task snapshot scans, timers/TimelineViews). Avoid
   publishing/rendering when there is no visible state change, but retain prompt
   task completion and permission responsiveness. The current Notch UI could
   not be observed reliably through automation.
7. **Run actual acceptance measurements.** On fixed hardware and documented
   workload, collect before/after five-minute idle CPU, continuous multi-provider
   append CPU/queue recovery, 1 GiB end-to-end append read volume, main-thread
   UI/search latency, and long-running memory. Do not infer these gates from
   parser fixtures or one `ps` sample.
8. **Rendered UI verification.** The debug app was launched but automation saw
   only an empty Notch surface; Usage/graph and transcript rendering were not
   visually verified. Perform a manual/debug UI verification after the final
   build.

## Important invariants

- Do not commit statistics and FTS from different source generations.
- Full parse, arbitrary incremental batches, replacement recovery, and restart
  recovery must yield equivalent statistics, cost, hierarchy and search rows.
- A visible main session can aggregate its child/subagent usage, but children
  must not appear as independent main sessions in list/Notch surfaces.
- No-change watcher events must not parse/index/rewrite cache rows.
- Hidden popovers must not keep chart/ranking work running; current-session,
  usage, Notch, permission and completion signals must remain timely.
- Third-party plugins may only rely on public SDK capability protocols. Do not
  add host-side provider-name branches for their format-specific behavior.
- Keep the existing user worktree changes. Do not use `git reset --hard` or
  broad deletion to obtain a clean state.

## Suggested first commands for the next agent

```bash
cd /Users/tinystone/claude-statistics
git status --short --branch
git diff --check
bash scripts/run-tests.sh

cd /Users/tinystone/claude-statistics/build/catalog-repo
git status --short --branch
git diff --check
bash scripts/run-parser-tests.sh
```

Then read `docs/PERFORMANCE_V2_EXECUTION.md`, inspect the exact diff before
editing, and advance the first outstanding item that has an executable test
strategy. Do not publish a release until runtime/acceptance evidence covers all
providers.
