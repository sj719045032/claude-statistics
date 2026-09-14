# Cross-provider performance optimization

Objective: complete and verify the cross-provider optimization plan agreed on
2026-09-10. This is an implementation checklist, not a claim of completion.
No release or publication is included in this task.

## Requirements and evidence

- [x] Capture repeatable baseline and after measurements: idle, continuous
  writes, multi-provider startup, large transcripts, UI/search, long-running memory.
  - Measured: large transcripts (869 MB Codex, 107 MB Claude), cold startup
    peak with the new Codex plugin (1.9–2.0 GB → 214.8 MB), 1 GiB append read
    volume, sustained multi-session appends, main-thread stalls, 5-minute
    footprint. Idle **0.750%** (gate < 1%) with TelemetryDeck's session stats
    off (kept at the owner's request; ~1.07% without it).
    Sustained appends 23.6% (gate < 30%). See "Acceptance measurements (item 7)".
- [x] Shared, bounded background work across providers; merge duplicate changes,
  prioritize interactive work, and cancel/invalidate work on stop/account changes.
  - Every parse/whole-file path is admitted by the scheduler ("Scheduler audit
    (item 5)"); the byte figure is an admission estimate, not a hard limit.
- [x] Accurate file identity/fingerprints and no-op detection; handle replacement,
  truncation, partial records, and writes during parsing without losing data.
  - "Foundation" and "Durable pipeline"; head/tail samples are not proof
    against arbitrary mid-file edits of an append-only history.
- [x] True bounded append reads with durable, transactionally committed parser
  checkpoints; full parse must equal arbitrary incremental batches/restart recovery.
  - 1 GiB history + 8 KB append reads 12,294 bytes end to end. CPU per append
    is still proportional to the compact state, now 2–4× cheaper: 249 ms at
    ~131k messages (was 1,023.7), 55 ms on a real 24k-message session (was 122).
- [x] Search index operations distinguish preserve, incremental update, and replace;
  indexing must remain correct after append, replacement, and crash recovery.
- [x] Claude/Cowork: independent source-file checkpoints, parent/subagent updates,
  and existing cross-file message deduplication semantics.
- [x] Codex: separate transcript and thread-metadata changes; preserve relationship,
  visibility, usage, and message semantics.
  - Rescan gated on a consumed-column digest and decided off the main actor;
    verified in the real app with the plugin bundled into the debug build (668
    checkpoints written, the installed copy refused as a duplicate). Not
    installed into the shared plugin directory. Per-row deltas measured and
    declined: the full metadata scan they would replace costs 7.9 ms.
- [x] Gemini: metadata-only scans, JSONL append/message replacement, changed-only
  JSON snapshot parsing, and shared results for statistics/index/preview.
  - Implemented, fixture/real-file tested, and verified in the real app with
    the plugin bundled into the debug build and enabled through a debug-only
    disabled-plugins file (the user's shared setting untouched): 21 live and 9
    archived sessions, 21 checkpoints written, 30/30 inline archives moved.
- [x] Old/other plugins: bounded compatibility fallback and optional SDK capabilities
  without provider-specific branches in the shared pipeline.
  - The fallback is admitted through the shared budget (oversized files one at
    a time), cancellable, guarded by before/after snapshots so a stale result
    never commits, and a duplicate bundle is refused before `dlopen`. The new
    capabilities are optional protocols with no provider branches. Stated
    limit: the memory of a single call into an old plugin's whole-result API
    is that plugin's; the host cannot bound it.
- [x] Incremental session/day/project aggregation; invalidation for pricing,
  timezone, parser-version changes; only one running aggregate per store.
- [x] Invisible views do not compute charts/rankings; usage/Notch/permissions and
  task completion remain timely and accurate.
  - Notch publishes only on change; hook-driven task scans resume instead of
    rereading transcripts; the completion card was verified rendered.
- [x] Asynchronous trends with stable bounded caches; bounded transcript paging
  and full-history asynchronous search.
  - Claude/Cowork, Codex and Gemini JSONL page; verified on real files and in
    the rendered app (Codex). Archived transcripts page too, streamed to a
    file first. Gemini's single-document JSON snapshots still fall back to the
    whole parse — the format has no record boundaries.
- [x] Release unused heavyweight state; coalesce usage requests, back off errors,
  bound archive/index jobs, and reduce idle Notch work without losing events.
  - Archive writes segmented, incremental and measured on real data; pre-v14
    blobs moved out of session rows. Archived transcripts are streamed to a
    file a piece at a time and paged. Old plugins' whole-result APIs remain
    unbounded.
- [x] Full regression suite, plugin integration builds, required debug launch,
  rendered UI verification, and before/after evidence for all supported providers.
  - Host 950 tests (8 gated skips) / catalog 39 tests green, plugin bundles
    built, debug launch done, Claude and Codex UI verified, Gemini runtime
    verified through a debug-only route. The release app still loads the old
    installed plugins.

## Proposed performance gates

Use fixed hardware, provider/plugin versions, and fixture sizes. Separate cold
indexing from steady state; report CPU time / wall time rather than one ps sample.

- Idle after settling: five-minute average CPU < 1%.
- Standard multi-provider append workload: initial average CPU budget < 30%,
  bounded queue, returns to idle after draining. Record write rate/concurrency.
- Appending to a 1 GB JSONL: reads proportional to append bytes, not old file size.
- Duplicate no-change events: zero transcript parse and index replacement work.
- Cached UI/search: no > 100 ms main-thread stalls.
- Repeated navigation/long run: bounded caches, no sustained memory growth.
- Correctness: full and incremental/recovered statistics, indices, hierarchy,
  model attribution, and costs agree.

## Baseline observations (not a reproduced issue #18)

- Source: host 4c0e3f7 (3.5.11), catalog af4e9c4; both clean at task start.
- Previous read-only sampling of installed 3.5.11 did not reproduce sustained
  110% CPU. Physical footprint was about 1.8 GB, lifetime peak 5.4 GB.
- Local cached dataset: 233 Claude, 722 Codex, 30 Gemini sessions. Largest
  cached transcript sizes: Claude 118,345,286 bytes, Codex 869,171,554 bytes.
- Existing suite baseline: 798 tests passed before the first source edits
  (2026-09-10 09:22:12 local time).

## Implementation log

Each entry must name changed behavior, test coverage, and measured evidence.
Unchecked requirements remain in scope even if an earlier phase is complete.

### Foundation, in progress

- Shared scheduler limits concurrent full/quick parses and visible aggregation.
  Weighted reservations serialize oversized files; cancelled waiters and failed
  operations release capacity. Not all IO paths use this budget yet.
- Index updates distinguish preserve, identified upsert/remove, and replace;
  batch serialization/commit failure rolls back statistics, fingerprint, index
  and checkpoint together. Compare-and-swap checkpoint IDs reject stale commits.
- Aggregation coalesces snapshots instead of running every revision in parallel;
  hidden popovers defer work. Switching providers closes the outgoing view state.
- Store tasks are tracked/cancelled; initialization queues watcher changes;
  generation checks reject stale results. A provider no longer closes the shared DB.
- SDK `TranscriptFileReader` now reads chunks from an actual file offset and
  captures inode/device/nanosecond timestamps. It handles split UTF-8/records,
  deferred partial tails, an EOF snapshot, and truncation. Claude now uses it
  for its checkpoint capability. Codex and Gemini now opt into the same
  capability in the catalog; legacy callers still need bounded migration.
- Dedicated lifecycle tests verify rejected late scanner results, shared DB
  survival on provider stop, and deferred hidden-view aggregation.
- Latest confirmed full suite: 880 tests passed, 0 failures (2026-09-10 11:00:08), via
  `bash scripts/run-tests.sh`; log `/tmp/claude-stats-build/xcodebuild-test.log`.
- Reader test: appending 18 bytes after a sparse 1 GiB history reads exactly
  those 18 bytes. An unchanged file at its checkpoint reads zero bytes. These
  are reader-level measurements, not yet end-to-end pipeline measurements.
- No CPU or memory improvement is claimed yet: runtime performance and remaining
  provider-specific paths have not completed validation.

### Durable pipeline and Claude/Cowork, in progress

- The optional SDK capability supplies per-physical-file checkpoints, exact
  source fingerprints, stats/quick projections and explicit index operations.
  It does not add requirements to the existing binary-plugin protocol.
- Host startup/dirty processing uses this capability, commits before publishing,
  and forces a rebuild if a retained checkpoint has an incomplete search index.
- Schema 12 → 13 preserves archives, metadata and indices across all providers.
  Migration is transactional and scans the FTS table once, not once per session.
- ClaudeProvider is connected to ClaudeCheckpointParser. Each record is decoded
  once for usage, preview and index. Each root/child file has its own offset.
  Changed usage IDs retract the old contribution and apply the new one; main
  messages take priority over child duplicates. Child deletion releases tokens,
  and root replacement preserves unchanged children. Child ordering is stable.
- Watcher paths map standard and Cowork subagents back to their root session,
  including deleted child paths; Cowork's file filter now accepts child changes.
- A real-Claude-provider integration test exercises the host validator, atomic
  DB writes, checkpoint decoding after DB reopen, child-only append, and search
  preservation. It caught mixed `/var` versus `/private/var` source keys returned
  by macOS directory enumeration; child keys now use the root path's namespace.
  All 852 tests pass after that fix (including 54 added since the 798 baseline).
- Parser state stores compact usage contributions, seen IDs and aggregates, not
  raw transcript bodies. Same-size rewrites and inode changes rebuild the affected
  source. Bounded head/tail hashes detect common truncate-and-regrow mutations;
  they are NOT proof against arbitrary edits in the middle of an append-only
  history. Snapshot validation rejects replacements and common boundary rewrites.
  Append-only validation now lets a writer advance beyond captured EOF while
  retaining the original consumed offset for the next update. Replaceable JSON
  snapshots still require strict validation. Reader tests interleave multiple
  writes and checkpoint commits and verify no records are skipped or duplicated.
- Claude fixture tests cover arbitrary byte-sized batches, split UTF-8, incomplete
  EOF JSON, complete JSON without a final newline, restart serialization, streaming
  revisions with model/date changes, tool dedup, child append/deletion, root
  replacement, cross-file ownership, and missing child-model attribution.
- Measurement: after a roughly 4 MB Claude fixture, an append reads exactly the
  appended bytes plus 4,096 bytes of bounded continuity samples. Child deletion
  reads zero transcript bytes. Checkpoint state in that fixture is below 20 KB.
  This is parser/fixture evidence, NOT whole-app CPU or memory verification.
- Remaining Claude work includes real-data runtime/CPU/memory validation and
  exercising the new append-safe checkpoints under sustained real writer load,
  bounding all cold/archive paths, and measuring full checkpoint serialization
  and aggregate reconstruction cost as message/slice counts grow. These costs
  still scale with compact state, even though transcript append IO does not.

### Codex/Gemini integration, in progress

- Both catalog providers now implement the optional checkpoint capability.
  Gemini JSONL stores per-message contributions and replaces old tokens/tools/
  index entries on revision. JSON snapshots decode once when changed. Revisions
  within one batch discard earlier pending index entries, preventing removed
  tools from being resurrected during commit.
- Gemini scanning caches header metadata by exact file snapshot and no longer
  decodes message bodies. Unchanged scans perform no metadata reads. Known
  appends do not force a rescan; new IDs/deletions still reconcile sessions.
- Codex root checkpoints retain cumulative token counters across restart;
  forked child checkpoints use child request usage, wait for NEW_TASK, and
  replay only the preceding task preamble for model attribution. Inherited
  parent messages/tokens never enter the child index/statistics. Tool-result
  index IDs are stable across output updates.
- `build/catalog-repo/scripts/run-parser-tests.sh` compiles actual Codex and
  Gemini plugin sources against the built SDK and runs macOS XCTest without
  launching the host app. All 16 tests passed at 10:15:04 on 2026-09-10, including
  arbitrary byte batches/restart, replacements, full-parse equality, forked
  ownership boundaries, scanner cache/no-op and bounded append IO.
- Both real plugin bundles built successfully against the local SDK (Gemini
  and Codex in dedicated `/tmp/*Plugin-checkpoint-build` directories). Not yet
  installed/reloaded in the actual host, so runtime integration remains open.
- Read-only real-data comparisons: 22 Gemini files and 4 Codex files (largest
  93,476,920 bytes) matched legacy full statistics and search content. Logs:
  `/tmp/gemini-checkpoint-real-data.log`, `/tmp/codex-checkpoint-real-data.log`.
  These are correctness checks, NOT a controlled production speed benchmark:
  the CLI uses debug compilation and its new path includes indexing/checkpoint
  serialization while the reported legacy time measures only statistics.
- Fixture IO: Gemini history 2,000,398 bytes, append 153, read 4,249, compact
  state 2,966 bytes. Codex history 2,000,548 bytes, append 304, read 4,400,
  compact state 841 bytes. Both use bounded continuity samples rather than
  rereading history. Cold index output and large compact states still require
  measured memory bounding; no whole-app CPU/footprint improvement is claimed.
- Equivalent-work parser benchmark (2026-09-10): rebuilt the CLI with `-O`,
  ran each mode in its own process, serially alternated checkpoint/legacy for
  three repetitions, and measured `/usr/bin/time -l`. Both modes produce stats,
  quick preview and index. These are warm-file isolated parser measurements,
  not the required whole-app idle/continuous-write/multi-provider acceptance.
  - Codex 93,476,920-byte file: legacy elapsed 3.349–3.375 s versus checkpoint
    1.131–1.143 s; user+sys CPU 3.35–3.38 s versus 1.15–1.16 s; peak physical
    footprint 687.7–706.3 MB versus 307.3–308.7 MB (decimal MB). Tokens and
    4,877 index rows match. Logs `/tmp/codex-measure-{legacy,checkpoint}-{1,2,3}.log`.
  - Gemini 685,245-byte snapshot: legacy elapsed 48.4–49.0 ms versus checkpoint
    32.8–34.9 ms; peak footprint 13.0–13.7 MB versus 11.1–11.3 MB. Tokens and
    103 index rows match. Logs `/tmp/gemini-measure-{legacy,checkpoint}-{1,2,3}.log`.
  - All 16 plugin regression tests also passed in the optimized build at
    10:18:33. The CLI supports `--compare <provider> <paths...>` for content-free
    equality checks and `--measure <provider> <legacy|checkpoint> <path>` for
    reproducible equivalent-work measurements.

### Shared usage refresh, in progress

- UsageViewModel now coalesces automatic/manual refreshes, shares credential
  recovery, and fences late responses by source generation and request ID.
  Automatic failures use bounded exponential backoff; server rate-limit
  deadlines also apply to manual attempts. A successful request resets backoff.
- Five new tests cover request coalescing/publication-before-return, a cancelled but
  non-cooperative old source, automatic backoff/manual recovery, rate-limit
  deadlines and credential recovery. All five executed and passed in the
  863-test full suite (Xcode project regenerated to include the new file).

### Incremental aggregate projections, in progress

- SessionDataStore now journals changed session revisions and feeds one
  IncrementalSessionAggregator actor. Replacement/deletion retracts old raw
  token contributions before adding new ones; unchanged historical slices are
  not traversed. Dates/projects/models have independent membership counts.
- Prices are captured in an immutable, lock-protected snapshot. Pricing changes
  invalidate derived views without marking session contributions dirty; timezone
  changes rebuild date attribution from five-minute source slices.
- Seven tests executed in the 870-test suite at 10:29:28: all four period modes,
  replacements/deletions, 100 repeated model/day moves, empty models, project
  moves, pricing/timezone invalidation, cancellation recovery, and a 400-session
  fixture. That fixture visits 40,000 slices initially and 101 slices for one
  changed session. No-op/repricing visit zero historical slices.
- Display buckets still need materialization/sorting on a projection update;
  this is not a claim that all derived work is O(1). Whole-app aggregation
  time/memory acceptance remains open.

### Asynchronous usage trends, in progress

- UsageView no longer runs trend/model folds from its rendering path. A stable
  snapshot clock advances on new data, usage refresh, or once per minute while
  visible. Keys include store identity, data version, bounds, granularity and
  model filter; hover/layout redraws alone do not generate new keys.
- UsageTrendViewModel uses the latest-only worker and shared interactive queue.
  It retains at most eight cached windows with a 2 MiB estimated cache budget,
  invalidates on source/data changes, and clears/cancels on hiding the view.
  One immutable pricing snapshot covers both chart and model breakdown.
- Cumulative charts retain at most 1,200 rendered samples, while visiting every
  source bucket and preserving the exact final tokens/cost. Ordinary short
  windows retain their prior samples. No transcript data is discarded.
- Seven new tests executed/passed in the 877-test suite at 10:37:31, covering
  off-main work, 200 identical requests computing once, a burst coalescing to
  first/latest, old-source rejection, LRU/byte eviction, cancellation, filter
  equality and bounded chart samples. These are not rendered-UI verification.

### Runtime and maintenance follow-up, in progress

- Required `bash scripts/run-debug.sh` built/installed/launched the debug app
  at 10:38:15 (PID 49430). SDK references were restored to published mode.
  The installed Codex plugin is still the legacy binary, and Gemini is disabled
  in the user's current configuration; new plugin runtime integration is not
  yet verified. No user plugin files were replaced.
- Startup logs show a full parse of one Codex session followed by repair of
  249 missing indices. Before the repair batching change, a five-second sample
  at 10:40:18 reported 122.8 MiB current physical footprint and a 3.0 GiB
  lifetime peak. The sampled main thread was predominantly waiting for events.
  This is not an equivalent-work before/after benchmark or an issue #18 repro.
  Evidence: `/tmp/claude-stats-debug-startup-sample.txt` and the diagnostic log.
- Index repair now commits/releases one session before parsing the next, under
  the shared budget. Cancelled or concurrently replaced sources are not
  committed. Archive jobs also share the budget and release autoreleased buffers
  per file. Single-file legacy parsing/compression can still allocate whole-file
  data, so bounded streaming maintenance remains unfinished.
- Three new maintenance tests passed in the 880-test suite at 10:58:34. They
  verify commit-before-next-parse, cancellation before commit/next session, and
  rejection of concurrent replacement. An initial test attempt timed out because
  it shared the real app startup queue; tests now inject an isolated queue while
  production continues using the global budget.
- Native UI automation could only retrieve the empty Notch window; desktop
  screenshot retrieval also stalled. The graph panel was not observed, so UI
  verification is explicitly NOT passed. The debug process remained alive after
  this observation failure. No restart was inferred from the automation timeout.

### Bounded transcript detail, Claude/Cowork done

- New optional SDK capability `PagedTranscriptProvider`
  (`Plugins/Sources/ClaudeStatisticsKit/PagedTranscriptProvider.swift`).
  `loadTranscriptOutline` streams the session once and returns one
  `TranscriptOutlineEntry` per display row — id, role, tool name, timestamp and
  the source byte ranges the row was built from, never a message body.
  `loadTranscriptPage` rebuilds exactly the requested rows by reading only those
  ranges through `TranscriptRecordReader`. Providers that do not adopt it keep
  the whole-file `parseMessages` path.
- Claude's parser was refactored so the whole-file parse, the outline pass and
  page materialization share one record→row mapping (`recordRows`) and one
  cross-record linker (`RowLinker`, owning row ids, streaming-revision replacement,
  duplicate `tool_use` suppression and tool-result routing). A page is therefore
  the row the whole-file parse would have produced, not a re-derivation.
  `TranscriptParser+Paging.swift` holds the two capability entry points;
  `ClaudeProvider` conforms.
- Two pre-existing defects surfaced while proving equivalence:
  - `toolSummaryAndDetail`'s generic branch picked "the first string value" by
    iterating a `Dictionary`, whose order is not stable across decodes. The same
    record produced different summaries on different parses. Now sorted by key.
    **Fixed here** because paging requires two decodes of one record to agree.
  - Attaching a tool result rebuilds the row without `editOldString` /
    `editNewString`, so an `Edit` row loses its diff strings whenever it has a
    result — which is nearly always, since `Edit` deliberately carries no detail
    of its own. Long-standing display behavior, **not fixed here**; both paths
    reproduce it identically and `testEditToolRowKeepsDiffStringsAndOwnDetailWins`
    pins it so a future fix has to change it deliberately.
- Host `TranscriptPagingModel` owns the window: an LRU of materialized pages
  bounded by page count and estimated bytes (12 pages / 8 MiB by default, both
  injectable), page loads through the shared scheduler at interactive priority,
  and role/tool filtering computed on outline changes rather than in a view body.
  `TranscriptView` renders outline entries with a placeholder row until its page
  arrives.
- Transcript search now runs off the main actor over the full history in
  page-sized batches, 250 ms debounced, cancelled by the next query, reporting
  matches progressively. It materializes and discards each batch, so a scan does
  not grow the window. The per-message `searchableTexts` cache the view used to
  build for every message is gone. FTS is untouched and still only backs the
  session list.
- Tests: `TranscriptPagingTests` (8) proves outline+pages equal the whole-file
  parse for streaming revisions, tool results, calls with their own detail,
  duplicate tool ids, queued and internal user messages, `Edit` diff strings, a
  final record without a newline, a `tool_use` without an id, arbitrary page
  window sizes, bounded per-row citation, outline size, and a replaced source.
  `TranscriptPagingModelTests` (9) covers open-without-materializing, single-page
  materialization, page-count and byte-budget eviction, full-history search
  equality with the whole-file parse, search not growing the window, query
  replacement, filters, and the non-paged fallback. Full suite: **903 tests, 0
  failures** at 2026-09-10 12:33 via `bash scripts/run-tests.sh`.
- Real-data evidence (`TranscriptPagingRealDataTests`, gated by
  `TEST_RUNNER_CLAUDE_STATS_REAL_DATA=1`; log
  `/tmp/claude-503-paging-realdata.txt`). Eight largest local Claude transcripts,
  every row rebuilt page by page and compared field by field against the
  whole-file parse — all equal. Largest file, 107,262,069 bytes / 11,742 rows:
  - one screenful cites **70,527 bytes**, the last page 61,763 bytes, versus a
    107 MB whole-file read;
  - retained outline **1,444,262 bytes** versus 5,076,267 bytes of row bodies,
    on top of which the old view also built a ~2.5× joined search-text cache;
  - the old per-keystroke main-thread scan measured **0.714 s** on this
    transcript — a 7× violation of the 100 ms main-thread gate, on every
    keystroke. That work is now off the main actor and debounced.
  - open latency is unchanged (outline 3.10 s versus whole parse 3.11 s): the
    outline still decodes every record. Materializing all pages afterwards costs
    1.89 s. **No open-latency improvement is claimed.**
- Codex and Gemini have since adopted the capability; see "Codex and Gemini
  transcript paging" below.

### Chunked reads were never bounded — the largest single finding

While measuring the Codex path on real rollouts, the SDK's `TranscriptFileReader`
— the foundation every checkpoint parser sits on — was found to peak at **944 MB
of physical footprint while reading an 869 MB rollout and retaining nothing at
all**. Its "memory is bounded by a chunk plus the largest record" comment was
false.

Cause: `FileHandle.read(upToCount:)` returns an **autoreleased** `NSData`. With
no pool per chunk, every 64 KiB chunk of the file stays alive until the whole
parse returns, so a chunked read costs exactly as much as reading the file
whole. Confirmed in isolation: an unpooled loop of `read(upToCount: 65536)` over
the 869 MB rollout grows the footprint by 873 MB; the same loop inside a pool
grows it by 0.

Fixed by copying each chunk into the reader's own buffer inside an
`autoreleasepool`, in `TranscriptFileReader`, `JSONMetadataReader` and the new
`TranscriptRecordReader`. The same defect class was fixed at the decode sites
that hand back autoreleased Foundation trees: `CheckpointedJSONLReader.readNext`,
Codex's record stream and checkpoint loop, and Gemini's two JSONL line loops.

Measured on the largest local Codex rollout (869,171,554 bytes), peak physical
footprint from `/usr/bin/time -l`, each mode in its own process:

| Path | Before | After |
| --- | --- | --- |
| SDK reader, records read and discarded (`--scanraw`) | 944 MB | **61 MB** |
| Reader + JSON decode, discarded (`--scan`) | 1,067 MB | **137 MB** |
| Codex checkpoint parse — runs on every startup and watcher event | 1,983 MB | **160 MB** |
| Codex `parseMessages` — opening the transcript | 3,448 MB | **167 MB** |

Correctness across those changes: token totals (1,077,013,288) and index rows
(2,288) unchanged; the transcript-row digest is byte-identical over 20 real
rollouts (10 forked subagents, 10 plain, up to 152 MB) plus the 869 MB rollout;
`--compare codex` passes 20/20 and `--compare gemini` passes on all 29 real
Gemini transcripts. Catalog suite: **22 tests, 0 failures**.

This is the most plausible explanation found so far for the memory in issue #18:
before the fix, one startup scan of this user's Codex history reached ~2 GB, and
opening that session's transcript reached ~3.4 GB. It is still not a reproduction
of the reported sustained 110% CPU.

Regression guard: `testReadingAWholeFileDoesNotRetainItsChunks` reads an 80 MB
fixture and asserts live allocator bytes (`malloc_zone_statistics`, not a
footprint delta — a footprint delta is hidden by malloc reusing pages other
tests freed, and did silently pass inside the full suite). Verified to fail at
79,342,592 bytes live with the fix reverted, and pass with it applied.

### Codex event streaming

- `CodexTranscriptParser.readEvents` returned `[Event]` built from a whole-file
  `Data`, a whole-file `String`, a `[String]` of every line and a decoded
  `[String: Any]` per record. It is now an `AnySequence<Event>` streaming through
  `TranscriptFileReader`, so `parseSession`, `parseSessionQuick`,
  `parseSearchIndexMessages`, `parseMessages` and `parseTrendData` all became
  bounded in one change rather than five.
- `readEventScope` keeps its forked-subagent semantics without the event list in
  hand: `session_meta` is read from a bounded 32-record head, and a forked child
  buffers only the events since the last `task_started` until the `NEW_TASK`
  marker arrives, then streams. A child with no marker still yields nothing.
- Six catalog tests cover plain streaming, the scope starting at the
  `task_started` before the marker, no `task_started`, no marker, the *last*
  `task_started` winning, and a final record without a trailing newline.
- The catalog CLI gained `--messages` (content-free row digest, for comparing two
  builds of a parser on the same real files), `--scan` and `--scanraw` (reader
  isolation for peak-memory attribution).

### The same defect on the Claude side

Auditing the host for the same pattern found it in every per-record path, and
measuring it required real transcripts — synthetic fixtures did not reproduce it,
so the assertions live in the gated real-data test rather than the hermetic
suite. Bytes still live when the call returns (`malloc_zone_statistics`,
measured before the surrounding pool drains), on the 107,262,069-byte transcript:

| Call | Before | After |
| --- | --- | --- |
| `parseSession` | 130,516,688 | **104,080** |
| `parseMessages` | 293,791,280 | **~0** |
| `loadTranscriptOutline` | 293,818,432 | **3,440** |

The outline number is the important one: the pass whose entire purpose is to
hold row identity instead of row bodies was holding 293 MB of bridged Foundation
objects — a defect in the paging work itself, caught by measuring it. Pools now
wrap each record in `parseMessages`, `loadTranscriptOutline`,
`parseSearchIndexMessages` and the three `TranscriptParser+Session` record loops.

`TranscriptPagingRealDataTests` asserts all three stay under 8 MiB for every
transcript it checks, so a future change that drops a pool fails there.

### Segmented transcript archive (outstanding item 2)

The archive read the whole transcript, compressed it into one blob and bound
that blob with a `SQLITE_TRANSIENT` copy. The hourly pass repeated all of it for
any session that had changed, and startup backfill did it for every session
without an archive. On this machine the archive holds 2.42 GB of Codex blobs,
the largest one blob of 526 MB, inside an 8.3 GB `data.db`.

Replaced by `TranscriptArchiver` over a v14 `transcript_segments` table:

- Each row is at most 4 MiB of raw source bytes, compressed on its own with the
  same raw-DEFLATE the old blob used, so a pass holds one raw segment and its
  compressed form, never the transcript.
- `session_cache.archive_state` records the committed generation plus a
  `TranscriptSourceCheckpoint` (identity, archived byte count, bounded
  continuity samples). Readers see only that generation below that offset.
- An unchanged source reads nothing. An appended source with an intact prefix
  compresses only the new bytes into the committed generation. Anything else
  (replacement, truncation, head/tail rewrite) writes a new generation that stays
  invisible until complete, so the previous archive survives a failed or
  cancelled rewrite.
- Commit is one small transaction: new state, the session fields the archive has
  always carried (project path, cwd, metadata), pruning superseded generations,
  and clearing a pre-v14 blob. Pre-v14 blobs stay readable until then. The v13→v14
  migration only adds a column and a table; nothing is rewritten at upgrade.
- The scheduler admission estimate for an archive pass drops from four times
  the file size to 12 MiB, so a large archive no longer has to run alone.
- `SessionParseOutcome.compressedTranscript` was removed. Nothing read it, but
  the test-only `parse(...)` default still whole-file-compressed every legacy
  parse into it. `saveTranscriptAndMetadata`, orphaned by this change, went too.

Measured on the 869,171,554-byte Codex rollout, each pass its own process,
`/usr/bin/time -l` (the store in the measuring process issues the same
statements `DatabaseService` does):

| Pass | Before (whole blob) | After (segments) |
| --- | --- | --- |
| Full archive — peak footprint | 1,400 MB | **29.5 MB** |
| Full archive — CPU | 18.0 s user | 18.5 s user |
| Stored bytes | 526,249,509 | 526,332,993 (+0.02%) |
| Hourly pass after a 1.4 MB append | full rewrite, same as above | **0.05 s, 8.8 MB, 1,398,105 bytes read** |
| Hourly pass, unchanged source | full rewrite | 0.3 ms, nothing read |

Round trip: 208 segments, largest 4,194,304 raw bytes, rebuilt with Python's
raw-DEFLATE decoder independent of the Swift code — SHA-256 identical to the
source. A full rewrite costs the same CPU as before; the win there is memory.
The CPU win is every later pass.

Tests (`TranscriptArchiverTests`, 11): exact round trip in bounded segments,
unchanged no-op, append compressing only new bytes in the same generation, a
single-segment archive byte-identical to the legacy blob, a replaced source
keeping its old archive until the new one commits, truncate-and-regrow rewritten
rather than appended, an interrupted append leaving only the committed prefix
visible and its orphan discarded, a cancelled pass committing nothing, a missing
session row writing nothing, a pre-v14 blob readable then superseded, and a v13
database migrating with its archive intact. Full suite **916 tests, 0 failures**.

Not bounded, stated explicitly:

- Reading an archived transcript (`loadArchivedTranscript`, used only once a
  session's file is gone) still returns the whole decompressed transcript,
  exactly like the old blob path. It is rebuilt segment by segment and holds the
  database lock per row, but the result is whole. Bounding it means feeding the
  paged transcript view from segments, which is item 1 work for archived
  sessions.
- Old plugins' `parseSessionAndSearchIndex` returns whole arrays by contract.
  The host cannot make that API stream; it commits and releases one session at a
  time under the scheduler, never two sessions' results at once. Builtin Claude
  and the catalog Codex/Gemini no longer take that path.
- Converting an existing 526 MB legacy blob is one full pass, paid the next time
  that session is archived. Space the old blob frees is reused by SQLite, not
  returned to the file system, without a `VACUUM`.
- The debug and release apps share one `data.db`. A v14 database opens fine in
  3.5.11, which only resets on older versions. But a session re-archived by v14
  code has no legacy blob left, so 3.5.11 cannot show that session's archived
  transcript once its source file is deleted.

### Real-database migration, backup and relaunch (2026-09-11)

- **Backup** (taken before relaunching the debug app on v14 code, at the user's
  request): `~/Library/Application Support/ClaudeStatistics/backups/data-v13-before-v14-2026-09-11.db`,
  8,306,302,976 bytes, taken with SQLite's online `.backup` while no process held
  the database. Verified through a read-only `immutable=1` URI: `quick_check`
  ok; 234 Claude / 729 Codex / 30 Gemini sessions, 986 archive blobs and 278,589
  FTS rows, identical to the live database. To restore: quit both the debug and
  release apps, copy the backup over `data.db`, and delete `data.db-wal` and
  `data.db-shm`.
- **The file name says v13, but the backup is `user_version` 14.** The live
  database had already been migrated before the backup, by `scripts/run-tests.sh`:
  its XCTest host is the full app, and it opens the real shared `data.db`. No
  launched app carried v14 code at that point. The migration only adds a column
  and a table, so the backup's content is still the pre-archiver state: 0
  segment rows, 0 `archive_state` rows, all 986 legacy blobs. The same test hosts
  also write to the user's diagnostic log. Filed as its own task; not fixed here.
- **Relaunch** (`bash scripts/run-debug.sh`, PID 9419): v14 schema confirmed on
  the real database, Codex scanned 668 sessions, and its full parse finished in
  14 s (729 sessions including 61 archived). **No real-app archive pass has run
  yet**, for correct reasons. The 7 sessions with statistics but no archive are
  Codex sessions whose source files no longer exist, so backfill has nothing to
  read. Sessions that already have a legacy blob are re-archived only by the
  hourly pass, and only once they change. The Claude store starts lazily. The
  real-app evidence for item 2 is therefore still the isolated measurement
  above, not a running app writing segments.
- Sample at 3 min 12 s after launch: 214.4 MB current footprint, 2.0 GB lifetime
  peak, 0.8% CPU over a 3 s interval; 0 segment rows, 0 `archive_state` rows,
  986 legacy blobs. One sample, not the five-minute idle average the gate asks
  for. The 2.0 GB cold-index peak matches the two earlier launches; it comes from
  the installed pre-optimization Codex plugin, which was not replaced.

### Codex thread-metadata separation (outstanding item 3)

Codex commits to `state_5.sqlite` on every turn (`updated_at`, `tokens_used`,
`preview`, `recency_at`), and the provider answered `shouldRescanSessions` true
for any change to that file or its WAL. So during an active Codex session nearly
every watcher batch took the host's slow path, even when it only appended to a
known rollout. That path re-queries all threads, stats every rollout, writes
every session's metadata into `data.db`, reloads every cache fingerprint,
re-diffs and replaces the session list. None of the per-turn columns feeds a
scan: `lastModified` comes from the rollout's mtime, never `updated_at`.

- **Catalog (`CodexSessionScanner`):** each scan records an order-independent
  digest of exactly the columns it consumes (`id, rollout_path, title, cwd,
  created_at, source, thread_source`, same `archived = 0` filter).
  `needsRescan(for:)` answers true only when that digest changed, when a rollout
  in the batch no longer exists, or when no scan has succeeded yet. Titles,
  cwd, archival, new threads and visibility (`thread_source`) still rescan;
  per-turn commits do not. Watcher filter, `changedSessionIds` and the new gate
  share one pair of path predicates.
- **The digest's cost was itself a finding.** Codex's `title` often holds the
  whole first user message (up to 64,314 bytes); the consumed columns total
  3.76 MB over 669 rows. Hashing them as Swift `String`s cost 12.9 ms. Hashing
  column bytes straight from SQLite's buffers costs **2.7 ms** (three runs of
  50 on the real database; the full scan, which computes the same digest, fell
  from 18.0 to 7.5 ms).
- **Host:** `SessionDataStore` is `@MainActor` and `FSEventsWatcher` delivers on
  the main queue, so `shouldRescanSessions` ran on the main thread; the gate
  would have put its SQLite read there on every WAL event. The store now queues
  the changed paths and asks the provider inside the batch's detached task. A
  batch that names no session and gets "no" drains the queue exactly as a
  finished batch does. This applies to every provider; no provider branch.
- **Tests:** 9 catalog tests (`CodexMetadataRescanTests`) — per-turn commits do
  not rescan; an append to a known rollout does not; title and cwd do and a scan
  records the new state; archiving does; a new thread does; a visibility change
  does and updates the visible-thread index; a deleted rollout does without a
  database change; the first batch before any scan does; an unreadable database
  does. Host `testRescanDecisionRunsOffTheMainActor` asserts the decision is off
  the main thread, a "no" scans nothing and a "yes" rescans. The thread
  assertion would fail on the previous code. Catalog **31 tests**, host **917
  tests**, 0 failures.

Not done, stated explicitly:

- A relevant change (a rename, an archive, a new thread) still triggers the
  whole rescan. Handing the host only the changed rows would need a new SDK
  capability for session deltas; such changes are rare next to per-turn commits.
- The digest still reads every consumed column of every thread on each WAL
  event — 2.7 ms off the main thread, not free.
- The catalog change is not installed, so the debug app still runs the old Codex
  plugin with its path-only rescan decision. The host half (off-main decision)
  is in the debug build.

### What one forced rescan cost, and why: blobs inside `session_cache` rows

Measured while quantifying what the Codex rescan gate saves, on APFS clones of
the real database backup (writes go only to the clones; the WAL is read before
the connection closes). Before the gate, Codex forced one of these on nearly
every watcher batch while it was running.

- One forced rescan's `saveSessionMetadata` over 729 Codex sessions: **2,773 ms**
  per call (gated test, 5 rounds). The same upsert in the SQLite CLI: 10.6 s and
  **1.91 GB of WAL** — which explains the 2.1 GB `data.db-wal` seen on this
  machine. Loading every cache fingerprint, by contrast: 1.3 ms.
- The cause is row layout. `transcript_blob` is column 6 of `session_cache`;
  `project_path`, `cwd`, `metadata_json`, `parser_checkpoint`, `index_complete`
  and `archive_state` come after it. To read any of them SQLite follows the
  blob's entire overflow chain.

| On the row holding the 526 MB legacy blob | Time |
| --- | --- |
| Read `metadata_json` (after the blob) | 1.06 s |
| Read `file_size` (before the blob) | ~0 ms |
| One-column `UPDATE` (WAL +4 KB: unchanged pages are not rewritten) | 1.23 s |
| Same `UPDATE` on a row without a blob | 5 ms |

- The same tax lands on every checkpointed parse of a live session that still
  has a legacy blob — `loadParseCheckpoint`, `hasCompleteIndex` and the stats
  commit each walk it — for every provider, independent of the rescan gate.
  For the active 869 MB rollout that is roughly 3.5 s of blob-walking per
  watcher batch. This is the strongest candidate so far for issue #18's
  sustained CPU; it is still not a reproduction of the report.
- First fix: the metadata upsert now skips rows whose metadata is unchanged
  (`DO UPDATE … WHERE metadata_json IS NOT excluded.metadata_json`). On the
  clone that removes the 1.91 GB of WAL (0 bytes written), but the conflict
  check still reads every blob (6.3 s cold), so it does not remove the read tax.
  Only getting the blobs out of the rows does that.

### Moving pre-v14 archives out of `session_cache` rows (schema v15)

- New table `transcript_legacy_blobs(provider, session_id, complete, blob)`;
  `complete` precedes `blob` so testing it never walks the blob. The v14→v15
  migration only creates the table.
- `relocateInlineLegacyTranscript` moves one session's blob in three steps: an
  invisible, correctly sized `zeroblob` destination (`complete = 0`); a copy in
  8 MiB chunks through SQLite's incremental blob I/O (`sqlite3_blob_read` /
  `sqlite3_blob_write`), with the database lock released between chunks, so
  neither the app nor SQLite ever holds a whole blob; and one transaction that
  marks the copy complete and nulls the inline column, matching both rows by
  length. Readers use only `complete = 1` rows, so an interrupted copy is never
  read, and one is discarded at the next start. `hasTranscript` counts a moved
  archive; a segmented archive commit deletes it as superseded.
- Each store starts the move after its initial load, smallest archives first,
  one session per background-priority scheduler reservation, and truncates the
  WAL when done. It is cancelled with the store's other background work.
- Tests (`LegacyTranscriptRelocationTests`, 7): exact bytes with a chunk size
  that divides nothing, later columns intact, a moved archive still decodes, an
  incomplete copy never read and then discarded, cancellation publishing
  nothing, no copy for a row without an archive, a segmented archive superseding
  a moved one, and a v14 database migrating to v15 with its inline archive
  readable and then movable. Full host suite **926 tests, 0 failures** (3
  gated real-data tests skipped).

Measured on an APFS clone of the real database (gated test
`testRelocatingInlineArchivesOnAClone`, then the SQLite CLI on the result):

| On the clone | Blobs inline (before) | Blobs moved (after) |
| --- | --- | --- |
| Forced-rescan `saveSessionMetadata`, 729 Codex sessions | 2,773 ms | **5.7 ms** |
| Read `metadata_json`, the 526 MB-archive row | 1.06 s | **1 ms** |
| One-column `UPDATE`, same row | 1.23 s | **4 ms** |
| Codex-wide metadata upsert without the new guard | 10.6 s, 1.91 GB WAL | **3 ms, 4 KB WAL** |

Moving all 986 archives took 36.3 s, once. The largest one's bytes are
identical after the move (526,249,509 bytes, SHA-256 equal to the backup's
inline copy).

**On the real database, before any deliberate relaunch:** `run-tests.sh` test
hosts boot the full app against it, so they migrated it to v15 and started
moving archives. When checked, 705 of 986 had moved, 281 were still inline, and
there was no incomplete copy. Data was moved, never removed; the backup remains.

**Relaunch on v15** (`bash scripts/run-debug.sh`, PID 44434, 02:53:15Z): the
Codex store moved its last 17 inline archives 16 s after launch, with no
incomplete copies; the WAL was truncated to 0 bytes afterwards. All 722 Codex
archives are now out of their rows. 264 remain inline — exactly 234 Claude and
30 Gemini — because the Claude store starts lazily and had not started, and the
Gemini plugin is disabled; they move when those stores start. Sample at 3 min
18 s: 71.1 MB current footprint, 1.9 GB lifetime peak (again the installed
pre-optimization Codex plugin's cold index), 1.0% CPU over 3 s. Codex's startup
full parse took 2 s, against 14 s on the previous launch when every blob was
inline — consistent with the mechanism, but not a controlled comparison.

**Compatibility, stated plainly:** 3.5.11 and the v14 debug build read only the
inline column. They cannot see a moved archive, and 3.5.11's startup backfill
treats such a session as unarchived and re-archives it whole into its row. So
running 3.5.11 against this database puts inline blobs back — correct data, but
the per-access tax returns for those rows until a v15 build moves them again.


### Codex and Gemini transcript paging (item 1, completed)

- SDK: `TranscriptOutlineEntry` gained an optional provider-owned `token`, and
  outline sources became `TranscriptSourceCheckpoint`s validated append-only.
  The first version required a source to be byte-identical, so an actively
  written transcript — the common case — would have rebuilt its outline on
  every page after any append. Replacement, truncation and boundary rewrites
  still invalidate it (tested on the host for Claude and in the catalog for
  Codex).
- Codex: the rollout stream now carries each record's byte range through the
  forked-subagent scope. One `transcriptRows` builder feeds `parseMessages`,
  the outline and pages. A tool row cites its call record and its last result
  record, and `token` carries the event index that names cached inline images.
  The random-UUID fallback id for a `function_call` without a `call_id` became
  positional, so ids agree across passes.
- Gemini: JSONL chats page. Pass one keeps each message id's first position and
  latest record; pass two decodes only the winning records, so a revision that
  changes a message's tool calls stays exact. A `.json` chat is one document
  with no row byte ranges; its outline throws and the host falls back to the
  whole-file parse.
- Tests: 8 catalog tests (Codex: outline+pages equal the whole parse in 1/2/4-row
  windows, deterministic ids without `call_id`, event-index tokens, the forked
  scope, append-valid/replace-invalid; Gemini: JSONL equality across a revision
  that adds a tool call, `.json` fallback, headerless chat). Catalog **39 tests,
  0 failures**; host adds `testAppendedSourceKeepsTheOutlineAndItsPagesValid`.
- Real data (`--paging` CLI, row digests of outline+40-row pages vs. the whole
  parse): Codex **20/20 rollouts identical**; Gemini 22 chats: 2 JSONL
  identical, 20 `.json` snapshots fall back as designed.
- 869 MB Codex rollout, each in its own process: outline alone 4.72 s, 160 MB
  peak, 1,679 rows; the first 40-row page 3.7 ms reading 125,238 bytes. The
  whole-file parse of the same file is now 4.71 s and 170 MB, so for this
  rollout paging adds little memory headroom — its display rows total only 3 MB
  and the earlier reader/autorelease fixes already bounded the parse. What paging
  adds is that a page reads 125 KB instead of the file, and the view retains
  row identity instead of every row.

### Plugin loader refuses a duplicate before dlopen (item 4 prerequisite)

`PluginLoader.loadOne` used to dlopen a bundle and only then discover, at
registration, that its id already filled that registry bucket. The image stays
mapped, and two copies of one Swift module in a process leave class lookup
ambiguous — so a bundled and a user copy of the same plugin could not safely
coexist. `PluginRegistry.conflictingBucket(id:kind:)` mirrors `register`'s
bucket mapping, and the loader now returns `.duplicateId` before dlopening.
Codex's provider and its terminal adapter share an id in different buckets and
still both load. Tests: `PluginLoaderDuplicateTests` — an executable-less
bundle with a taken id returns `.duplicateId` (reaching dlopen would give
`.bundleLoadFailed`), and the same id in another bucket still reaches dlopen.
Host suite **929 tests, 0 failures**.

### New Codex plugin in the real app, without touching the shared plugins (item 4)

- `scripts/run-debug.sh` gained `DEBUG_BUNDLED_PLUGINS` (colon-separated
  `.csplugin` paths): each is copied into the debug app's `Contents/PlugIns`
  before signing. Bundled plugins load before the user plugin directory, and
  with the pre-dlopen duplicate check the user copy is refused without being
  loaded. The shared `~/Library/Application Support/Claude Statistics/Plugins`
  directory the release app reads is untouched.
- `CodexPlugin` was built from the catalog sources against the local SDK
  (`sdk-mode.sh local`, `xcodebuild` Release into `/tmp`, mode restored to
  published afterwards); it links `@rpath/ClaudeStatisticsKit`, sharing the
  host's framework. Gemini was not bundled: it is disabled in the user's
  configuration, and the disabled check runs before loading.
- Relaunch (PID 55296, 03:16:48Z), from the diagnostic log:
  `PluginLoader (bundled): loaded=1`, then
  `skipped CodexPlugin.csplugin: duplicateId(id: "com.openai.codex", bucket: "provider")`
  for the user copy. After the first run all 668 live Codex sessions carry
  parser checkpoints (the old plugin wrote none).
- Cold index with the new plugin: **peak physical footprint 214.8 MB**, against
  1.9–2.0 GB on every earlier launch with the old plugin; settled 86.3 MB at
  3 min 56 s. That first checkpointed pass over all 668 rollouts (~2.4 GB) cost
  2 min 23 s of CPU; later launches resume from checkpoints.
- Not covered at runtime: Gemini (disabled by the user), and the release app,
  which still loads the old installed plugin.

### Scheduler audit (item 5)

A survey of every host path that runs provider parsing or whole-file reads
found them all admitted through `BackgroundWorkScheduler` — startup and rescan
scans, checkpointed and legacy parses, index repair, archiving, legacy-blob
relocation, transcript outline/pages and full-history search — except four in
`SessionViewModel`, which ran whole-file parses in bare `Task.detached`:
detail stats (`loadStats`), the non-paged transcript fallback and subagent
expansion (`loadMessages(at:)`), archived transcripts (`loadMessages(for:)`),
and session trends (`loadTrendData`, both branches). Detached tasks bypass the
byte budget and do not inherit cancellation, so a parse kept running after its
view was gone. All four now run through the shared scheduler at interactive
priority, awaited in the caller's task: a view that goes away cancels its
queued request, and a result arriving after cancellation is dropped (the
scheduler's post-operation cancellation check). `loadStats` keeps one task per
selection and cancels the previous one. No provider branch was added.

Still as before, noted only: archived transcripts are decoded with Claude's
parser whatever their provider — pre-existing and outside this change.

### Notch and inactive work (item 6)

From reading `ActiveSessionsTracker`: `refresh()` runs on a 15 s timer and on
events; it assigned both `@Published` properties unconditionally (every tick
re-rendered every Notch row), persisted runtime state unconditionally, and for
every idle Claude session still holding a task, re-ran the task scan from byte
0 of its transcript — through a scan that read the whole file into one `Data`
and decoded every line with no autorelease pool.

- `sessions` and `totalCount` are assigned only when they change
  (`ActiveSession` is `Equatable`). Rows tick elapsed time through their own
  `TimelineView`s, and waiting/permission cards through their own timers, so
  nothing depended on the periodic republish.
- The persistor skips a state identical to the last one it was handed.
- Idle repair skips a transcript whose size still equals the offset of its last
  scan. When it does run it still rescans from the start, as before (the commit
  that introduced it records no reason for the full scan, so its semantics are
  kept).
- `taskScanResult` streams through `TranscriptFileReader` with a pool per
  record; `nextOffset` and `clearsCurrentTask` are computed as before.
- The 2 s liveness loop already refreshed only when something changed; left as is.
- Tests: `RuntimeStatePersistorSkipTests` (identical state not rewritten,
  changed state written) and `RuntimeTaskScanTests` (full scan, incremental scan
  reaching the full scan's state, unterminated final record, empty reminder
  clearing). Host suite **934 tests, 0 failures**.
- Present-day effect on this machine, stated plainly: the persisted runtime
  held 4 sessions and no idle Claude session with a task, so the repair fix
  removes no current work here. Rendering cost was not profiled with
  Instruments; the idle CPU figure below is the whole-app evidence.

### Acceptance measurements (item 7)

**Idle CPU, second attempt — also not a pass, and not idle.** Plain debug launch
(PID 96941), 90 s settle, 300 s window with no tool calls from this session:
37.35 s of CPU, **12.45%**; footprint 57.0 → 59.1 MB (peak 67.9 MB). The
machine was not idle: another Claude Code session (a 15 MB transcript plus a
subagent) was writing during the window, and the log shows four Notch
permission prompts (`decision=ask`) and a suppressed `taskDone` for it.

A follow-up 180 s trace in 5 s buckets showed a floor of 0.03–0.13 s per bucket
(~1–2.5%) with spikes of 0.28–0.96 s every 15–20 s (~3.9% overall). A 30 s
`sample` attributed the spikes to `TranscriptFileReader.readNext()` plus
`JSONSerialization` — the Notch task scan, the only host reader of transcripts
while the Claude store is not running. **Root cause (pre-existing):**
`taskScanResult` only resumed from its recorded offset when tasks were already
known, so every hook event of a session that never used the task list re-read
and re-decoded its whole transcript. That cost grows with the transcript, per
tool call, for every active Claude session — plausibly another part of issue
#18 — and after every Stop, which clears the displayed tasks, the next hook
event paid the same full rescan. Fixed: the scan result now carries the task
state it reached (`tasks`, including all-completed tasks that produce no
snapshot); the tracker keeps it as `RuntimeSession.taskScanTasks` beside the
offset and resumes from there with the displayed tasks, else the carried
state. Only state persisted by an older build (no carried tasks) still starts
from byte 0. `RuntimeTaskScanTests` covers resuming with no tasks, a reminder
appended later, and reopening a task after all were completed — each equal
to a full scan. On this machine's largest Claude transcript (107,262,069
bytes; gated `RuntimeTaskScanRealDataTests`), one scan from byte 0 costs
**607.1 ms** — with the `memchr` reader below, so mostly JSON decoding — and
resuming at the recorded offset **0.10 ms**. Before the fix a session without
displayed tasks paid the former on every hook event.

The same sample showed `Data.firstIndex(of:)` walking bytes through protocol
witnesses (not specialized across the SDK module boundary) as the hottest
frame inside `TranscriptFileReader.readNext()`. The newline search now uses
`memchr` over the buffer's bytes. `--scanraw` over the 869,171,554-byte rollout
(reader only, records discarded, same 32,776 records and bytes): **2.25–2.33 s
→ 0.21–0.24 s** wall, user CPU **2.09 s → 0.06 s**, peak footprint unchanged
at 58 MB. Every transcript reader in the SDK gets this — Claude/Codex/Gemini
checkpoint parses, outlines, pages and the Notch task scan. Host suite **940
tests, 6 skipped (gated), 0 failures**; catalog **39 tests, 0 failures**.

**Idle CPU after both fixes — 1.14%, the < 1% gate narrowly not met.**
Relaunched with the new Codex plugin bundled (PID 81243), 90 s settle. A 180 s
trace: 2.07 s of CPU (1.15%), buckets 0.03–0.10 s with a single 0.15 s — the
0.28–0.96 s spikes are gone, and no app frame reaches the sample's heaviest
top-of-stack frames. Then a quiet five-minute window from 04:14:19Z: no tool
calls from this session, and no transcript under `~/.claude/projects` or
`~/.codex/sessions` grew during it. **3.42 s of CPU, 1.140% average**;
footprint 52.1 → 52.7 MB (peak 65.3 MB). The 5 s buckets are flat at
0.03–0.07 s with three at 0.11–0.16 s: a steady floor, not bursts.

A 60 s `sample` of that floor has no dominant app frame. The largest single
item (~138 samples, ~0.23% of a core) is not ours: the TelemetryDeck SDK's
`SessionManager` runs a 1 s main-thread timer that JSON-encodes up to 90 days
of stored sessions and writes them to UserDefaults on every tick. On macOS it
stops that timer only on `NSApplication.didResignActiveNotification`; a
menu-bar app that is never activated never resigns, so the timer runs for the
app's whole lifetime (and counts background time as session duration). The
only public switch is `TelemetryDeck.Config.sessionStatsEnabled = false`,
which also drops the retention metrics (average session length, distinct days,
session count) from the analytics — a product decision, not made here. Next:
the 2 s liveness loop re-sanitizing every runtime session (~50 samples,
~0.08%), then SwiftUI Notch/menu-bar layout and usage refresh, each smaller.

**Measured with the TelemetryDeck timer off — 0.870%, under the gate.** To
put a number on that decision, `config.sessionStatsEnabled = false` was added
for one debug build only, the source restored byte-for-byte right after the
build (and the app rebuilt from it after the measurement). Same launch, same
plugins, 90 s settle, a quiet five-minute window from 05:01:37Z (no tool
calls, no transcript grew): **2.61 s of CPU, 0.870% average** (was 1.140%),
buckets 0.02–0.05 s with three at 0.08–0.11 s, footprint 54.0 MB. So the idle
gate passes exactly when that one line ships — which trades away the
retention metrics (and today's inflated session lengths) in TelemetryDeck.

**Defaults observers, a lossless part of the same cost.** TelemetryDeck's
once-a-second UserDefaults write posts `UserDefaults.didChangeNotification`,
and two host observers reacted to every one: `GlobalHotKeyManager`
unregistered and re-registered its Carbon hot keys, and `MenuBarUsageStrip`
bumped its revision, re-rendering the status item (the view churn seen under
the display link). Both now act only when a value they read changed — the
shortcut per action, the visible descriptor ids. (`SkipConfirmKeyMonitor`
already published only on change.) A 30 s sample afterwards:
`registerCurrentShortcut` 0 samples, `MenuBarUsageStrip.body` 3 (the 60 s
sample before had 15 and 9). Idle with TelemetryDeck as shipped: **1.070%**
over five minutes from 05:14:00Z (was 1.140%; two transcripts grew during
this window), footprint 54.1 MB.

**Final code — 0.750%, gate met.** With the observer fixes and
`config.sessionStatsEnabled = false` in `ClaudeStatisticsApp.swift` (kept
at the owner's request; deleting it restores TelemetryDeck's retention
metrics, and idle is then ~1.07%), a quiet five-minute window from 05:23:47Z
— no tool calls, no transcript grew: **2.25 s of CPU, 0.750% average**,
footprint 53.8 MB. Host suite 950 tests, 0 failures.

**Re-measured after four hours of uptime — not idle.** Same process (PID
93194), two windows while two other Claude Code sessions
(`work-cbdc-chain`, `work-sign-flow-engine`) were writing and the app was
answering their hooks (two permission prompts, a Notch focus action, usage
requests): 1.453% from 09:38:21Z, then 1.270% from 09:45:07Z with 6
transcripts growing; the first 250 s of the second window, before their
bursts, averaged 0.94%. Neither is an idle measurement, so the quiet-window
figure stays 0.750%. Footprint: 53.8 MB after launch, 88.0 MB after 4 h 16 min
(peak 117.4 MB), 89.2 → 93.3 MB across the second window — growth under
activity, not yet checked against the long-run memory gate.

**Idle CPU, first attempt — not a pass.** Debug build with the new Codex plugin
bundled (PID 57958), 120 s settle, then a 300 s window: 9.41 s of CPU, a
**3.14% average** against the < 1% gate; footprint 56.3 → 61.7 MB (peak
71.5 MB). The window was not quiet: this Claude Code session kept firing hooks
into the app's Notch tracker the whole time, and a test host (same debug
runtime directory) started during it. A quiet re-measurement follows below.

Two gated tests (`TEST_RUNNER_CLAUDE_STATS_ACCEPTANCE=1 bash scripts/run-tests.sh`;
host suite **936 tests, 0 failures** with them enabled):

- **1 GiB append, end to end** (`AppendAcceptanceTests`): real Claude provider,
  host parse validator and database. History 1,074,417,146 bytes; the first
  checkpointed parse read 1,074,419,194 bytes in 63.5 s. Appending one
  8,198-byte record, the next pass read **12,294 bytes** — the append plus
  4,096 bytes of continuity samples. The read-volume gate holds end to end.
  **The CPU gate does not:** that append pass took 1,023.7 ms. Reads no longer
  scale with the history, but decoding and re-encoding the compact checkpoint
  state does — this history holds ~131,000 messages. That cost was listed as
  unmeasured; it is now measured, and it is a remaining item.
- **Sustained multi-session appends** (`SustainedAppendAcceptanceTests`): the
  real Claude checkpoint parser over 4 transcripts (~2 MB history each), the
  real `SessionDataStore`, database and scheduler, a watcher driven by the test,
  temp files only. Each session received one record every 100 ms for 20.7 s —
  800 appends, 1,756,800 bytes. Parse work 6.50 s, **31.5% of one core** over
  the window; every session's committed token total exact; the queue drained
  **0 ms** after the last write; longest main-thread stall **18.9 ms** (gate:
  100 ms). The "< 30% initial CPU" gate is narrowly missed at this synthetic
  rate, which is far above normal use; the gate never defined its standard
  workload, so this is reported as a miss, not a pass. The per-append cost
  (~8 ms) is again dominated by checkpoint state, as above.

### What one append costs on a real Claude session

The acceptance history above (131k synthetic messages) is extreme. The gated
`CheckpointAppendCostRealDataTests` copies this machine's largest Claude
transcript (107,262,304 bytes, 24,366 messages, 667 five-minute slices) to a
temp directory and database, commits it, appends one assistant record and
times each stage:

| Stage | ms |
| --- | --- |
| `loadParseCheckpoint` (JSON, state as base64) | 4.9 |
| `ClaudeCheckpointParser.parse` (decode + re-encode the whole state) | 82.0 |
| `JSONEncoder` of the checkpoint for the write | 7.2 |
| Pipeline: validator parse / database save | 96.9 / 25.6 |

The state is 3,030,160 bytes; the stored checkpoint 4,040,676 (base64). About
122 ms per append, almost all of it proportional to the session's history
rather than the append: the whole state is decoded and re-encoded by the
parser, the checkpoint is decoded twice (validator and the save's
compare-and-swap) and encoded once more, and the full blob rewritten.

### Compact checkpoint state and container

The stages above led to three changes, none of which alters what a
checkpoint means:

- `ClaudeCheckpointParser` stores its per-message ledger and seen-ID sets in a
  compact binary layout (`CCP2`: length-prefixed strings, fixed-width
  integers, exact `Date` bit patterns) with the small remainder as a JSON
  header. A standalone `-O` benchmark at 24k messages: JSON Codable 78.5 ms
  encode / 84.4 ms decode, binary plist 122.4 / 182.6, the compact layout
  8.0 / 6.7. States written as whole JSON by earlier builds still decode and
  are rewritten in the new layout on the next append — no reparse.
- `ParseCheckpointCoding` stores a checkpoint as `CSPC` + a JSON header + the
  raw state bytes instead of JSON with the state as base64; whole-JSON rows
  still load.
- The commit's compare-and-swap reads only the stored checkpoint's ID
  (`loadParseCheckpointID`) instead of decoding the whole checkpoint again.

Same real session, same append:

| Stage | Before ms | After ms |
| --- | --- | --- |
| `loadParseCheckpoint` | 4.9 | 0.8 |
| `ClaudeCheckpointParser.parse` | 82.0 | 46.5 |
| Checkpoint encode for the write | 7.2 | 0.2 |
| Pipeline: validator parse / database save | 96.9 / 25.6 | 44.7 / 10.8 |

State 3,030,160 → 1,895,153 bytes; stored checkpoint 4,040,676 → 1,895,621.
Decoding the state now takes 21.2 ms, most of it the JSON header's two
`SessionStats` (667 slices each). Acceptance, rerun: the 1 GiB append still
reads 12,294 bytes and now costs **249.4 ms** (was 1,023.7); the sustained
multi-session run uses **23.6%** of one core (was 31.5%; gate < 30%), drains
in 0 ms, longest main-thread stall 7.9 ms. Tests: `CheckpointStateEncodingTests`
(exact round trip including nils, empty strings, extreme integers and
non-ASCII IDs; binary, legacy-JSON and full parse equal after the same
append; an unreadable state falls back to a full parse; container round trip,
legacy rows, ID-only read, malformed input).

### Archived transcripts: streamed to a file, then paged

Opening a session whose source file is gone used to decompress its whole
archive into memory (`loadArchivedTranscript`) and decode it with Claude's
parser whatever its provider — for Codex and Gemini archives the wrong parser.
Now:

- `DatabaseService.writeArchivedTranscript(provider:sessionId:to:)` writes
  the archive to a file one stored piece at a time: v14 segments are
  decompressed one by one; a pre-v14 single blob (inline or relocated) is read
  through incremental blob I/O in 8 MiB steps and inflated as a stream with
  the Compression framework into a 1 MiB buffer. A read whose blob changed size
  underneath fails; a failure leaves no file.
- `ArchivedTranscriptFile` owns that file in its own temporary directory under
  the original file name (providers may read identity from it) and deletes it
  when the last owner lets go. `TranscriptPagingModel` holds it while paging.
- The transcript view pages archived sessions through the store's provider
  exactly like live ones; the whole-parse fallback and session trends use the
  provider's own parser on the same file. `loadArchivedTranscript` and
  `SessionDataStore.resolveTranscriptData` are gone; the archive tests now read
  archives through the new writer, so their existing assertions cover it.
- Tests: a 5,000-record pre-v14 archive inflated in 1 KiB reads, inline and
  after relocation; a truncated blob leaves no file; the temporary file lives
  exactly as long as its owner and a failed write leaves nothing. Host suite
  **949 tests, 7 skipped (gated), 0 failures**.
- Real data (gated `ArchivedTranscriptRealDataTests`, on an APFS clone of the
  live database — the original is never opened): all **987** stored archives
  (Claude, Codex and Gemini; segmented, relocated and still-inline) streamed
  to files, 5,993,859,383 bytes in total and 869,171,554 the largest, in
  26.4 s with **12 MB** of peak-footprint growth and 0 failures. Five archived
  Claude transcripts page to exactly the rows a whole parse produces.

### Gemini in the real app, without touching the user's settings

The user has Gemini disabled in the shared `disabled-plugins.json`. The debug
build was launched with `CLAUDE_STATISTICS_DEBUG_DISABLED_PLUGINS` pointing at
a copy of that list without `com.google.gemini`, the new `GeminiPlugin` built
against the local SDK (`sdk-mode.sh local`, then back to `published`) and
bundled with `DEBUG_BUNDLED_PLUGINS`, and the debug app's own
`selectedProvider` set to Gemini. The log and the database, read-only:

- The installed Gemini and Codex copies were refused as duplicates before
  `dlopen`; the bundled ones loaded.
- `Initial scan complete — provider=gemini sessions=21`, 9 archived sessions
  from the cache, `Full parse complete — 30 sessions, 255 messages, 5566373
  tokens`, then `[gemini] Moved 30/30 pre-v14 transcript archives out of
  session rows` — the last provider's inline archives (0 left inline).
- 21 Gemini checkpoints, all in the new `CSPC` container.
- The shared `disabled-plugins.json` is byte-identical afterwards.
- Rendered: a window-only capture with the Sessions tab and the first Gemini
  session's transcript open showed the header and message count, search
  field, User/Gemini/Tools filters, Gemini rows with a collapsed long row, the
  scroll-to-bottom control and Gemini selected in the provider switcher. The
  capture was deleted after checking; the debug app's `selectedProvider` was
  set back to Codex.

### Rendered UI verification (item 8)

UI automation has no accessibility access here (`osascript` is refused
assistive access), but `screencapture` works. Three `#if DEBUG` launch switches
let a build open itself for a screenshot without clicking:
`CLAUDE_STATISTICS_DEBUG_SHOW_PANEL=1` (opens the panel 4 s after launch),
`CLAUDE_STATISTICS_DEBUG_TAB=<Sessions|Stats|Usage|Settings>` (initial tab) and
`CLAUDE_STATISTICS_DEBUG_OPEN_TRANSCRIPT=1` (opens the first listed session's
transcript once). A fourth, `CLAUDE_STATISTICS_DEBUG_DISABLED_PLUGINS=<path>`,
gives the debug build its own disabled-plugins file, so a plugin the user has
disabled (Gemini here) can be enabled for a debug run without touching the
shared `disabled-plugins.json` the release app reads. Release builds compile
them all out. `run-debug.sh` launches with
`open -n`, so they are passed with `open -n --env …`.

- **Transcript view — verified.** Sessions tab with the bundled new Codex
  plugin: a 505-message Codex transcript rendered through the paged path —
  header and count, search field, User/Codex/Tools filters, a user row with its
  inline image (the event-index `token` resolving the cached image), an
  assistant row, `wait` tool rows, and the scroll-to-bottom control.
- **Notch completion card — verified.** A window-only capture
  (`screencapture -l`, located through `CGWindowListCopyWindowInfo`, so nothing
  but the app's own window is recorded) caught the Notch "Task completed" card
  for the running Claude Code session, rendered with the session's final reply
  moments after it ended — after the item 6 idle-work reductions, completion
  events still surface promptly.
- **Usage trend chart — verified.** With the debug app's own `selectedProvider`
  preference switched to Claude (restored to Codex afterwards; the release app's
  settings are separate), a window-only capture of the panel showed the 5 Hour
  / 7 Day / 7 Day Fable 5 bars, the 5h / 7d / 7d Fable 5 window picker, the
  cumulative 5-hour chart (tokens and cost, 09:10–14:10 axis, curve ending at
  the capture time, i.e. `dataEnd` clamped to now) and the Tokens & Models card
  — all through the asynchronous `UsageTrendViewModel` path. Selecting Claude
  also started its store in the real app, which logged
  `[claude] Moved 234/234 pre-v14 transcript archives out of session rows`;
  only Gemini's 30 remain inline, because its disabled plugin never starts a
  store. Every capture was deleted after checking.
- **Codex Usage tab — panel verified, chart not exercised.** The Codex account card,
  "7 Day 23%" bar and window chip render; the area where the window chart would
  be is empty. Not a regression: Codex reports that weekly window resetting in
  28 d 23 h, so its start (reset − 7 days) lies ~22 days in the future. HEAD's
  `windowTrendInfo` returned nil on `start < snapshotTime`, so 3.5.11 draws
  nothing in this state either; the async version skips the request under the
  same condition.

### Debug runtime sample after the reader fix

`bash scripts/run-debug.sh` rebuilt, installed and launched the debug app
(PID 79151). Samples via `vmmap --summary`:

- 11 s in, mid cold-index: 814 MB current footprint.
- 75 s in, settled: **58.5 MB current footprint, 0.8% CPU**.
- Lifetime peak for the run: **1.9 GB**, during cold indexing.

A second launch after the Claude-side pools: settled at 106 s to **56.2 MB
current footprint, 0.0% CPU**, lifetime peak **2.0 GB**. The settled figures are
one sample each on an idle machine, not the five-minute average the gate asks
for.

The previous pass's comparable sample was 122.8 MiB current with a 3.0 GiB
lifetime peak. The peak is still high because this debug app loads the user's
**installed** Codex plugin, which predates all of this work: it does not
implement the checkpoint capability at all, so the host falls back to its
whole-file parse. The catalog fixes are built and tested but not installed —
`dev-install.sh` mutates the user's shared plugin directory and needs explicit
authorization. Until that happens, no whole-app claim can be made about the
Codex path; the isolated parser numbers above are the evidence that exists.

## Release (2026-09-14, authorized by the owner)

Order: SDK, then host, then catalog, then local install.

- **Pre-flight.** The new SDK framework exports 3,093 symbols against 3.5.11's
  2,795: 298 added, **0 removed**, built with library evolution — plugins
  already installed from older catalogs keep loading on the new host (the
  debug build loaded the six installed terminal/app plugins throughout).
  Pushing as `tinystone007` is refused (403); publishing ran as
  `sj719045032`.
- **SDK `sdk-v0.7.0`** (API 0.5.0): xcframework rebuilt on `main` after the
  API bump, checksum `aac132a2c1e6fdba87afa1d0b3582fcfdc26ef1b891c34b6f5115f998cd8a042`,
  `scripts/sdk-mode.sh` and `Package.swift` updated in `ac1f4a9`, `main`
  pushed, release created with the tag on that commit; the downloaded asset's
  checksum matches.
- **Catalog ABI check before release** — every plugin built as
  `release-plugins.sh` builds them, against the published SDK: only
  CodexPlugin (81) and GeminiPlugin (79) import symbols 3.5.11 lacks, and both
  require API 0.5.0; the other 14 import none; no plugin imports anything the
  new SDK lacks.
- **Host 3.6.0** via `scripts/release.sh 3.6.0` with bilingual notes: DMG,
  ZIP and Sparkle deltas from 3.5.9, 3.5.10 and 3.5.11 uploaded to
  https://github.com/sj719045032/claude-statistics/releases/tag/v3.6.0;
  appcast commit `78d8c2e` pushed, and the served `appcast.xml` lists 3.6.0
  with all three deltas.
- **Catalog v1.3.8** via `release-plugins.sh 1.3.8`: 16 bundles rebuilt
  against sdk-v0.7.0 and uploaded, `index.json` (`7462b29`) listing Codex and
  Gemini 1.2.0 requiring API 0.5.0. The owner's install got the 3.6.0 app and
  both plugins from the published assets after checksum checks.

- **Codex 1.2.0 crashed 3.6.0 — found on the owner's machine minutes after
  release.** After the new plugin was trusted and hot-loaded, the app died
  with `EXC_BAD_ACCESS` in `sqlite3_step` under
  `CodexSessionScanner.scanSessions()` (no other thread was in SQLite).
  `openOrReuseDB` validated the cached handle under `dbLock` but returned it,
  and callers used it unlocked; when Codex checkpointed its state database,
  another caller saw the new size/mtime and closed the handle under the first
  one's query. The race predates this work, but the new off-main
  `needsRescan` → `metadataDigest()` call made it concurrent with scans on
  exactly the database changes that trigger the reopen. Contained within
  minutes: the catalog's Codex entry was rolled back to 1.1.6 (`20a598e`,
  loads on 3.6.0 through the compatibility path), and the owner's install
  restored to 1.1.6 from the backup — 3.6.0 relaunched with 668 Codex
  sessions and no further crash. The backups (3.5.11 app, Codex 1.1.6,
  Gemini 1.1.0) are in
  `~/Library/Application Support/ClaudeStatistics/backups/pre-3.6.0/`.
- **Reproduced before fixing.** `CodexMetadataRescanTests.testConcurrentScansAndDigestsSurviveHandleReopening`
  runs eight threads of `scanSessions()` / `metadataDigest()` against a
  fixture database while another connection updates and
  `wal_checkpoint(TRUNCATE)`s it 400 times, forcing handle reopens. On the
  1.2.0 scanner the test binary died with `Segmentation fault: 11`.
- **Fixed in Codex 1.2.1.** The handle is now only used, reopened or closed
  inside `withDatabase { db in ... }` with `dbLock` held; the scan's query runs
  there and its results are published after the lock is released. The
  stress test passes, and all 40 catalog tests passed in the build and five
  further runs of the same binary. The same bug class was checked in the
  host: every `DatabaseService` path (archive segments, legacy blob chunks,
  relocation, checkpoints) prepares, steps and finalizes its statements and
  opens and closes incremental blob handles within one hold of its lock, and
  hands out only row ids and copied bytes — a row moved concurrently makes
  `sqlite3_blob_open` fail, which callers already treat as "not stored". No
  other catalog plugin uses SQLite.
- **Claude sessions that never committed (fixed for 3.6.1).** Watching 3.6.0
  after the hotfix, the log showed "Giving up queued retries" for two large
  Claude sessions — also present in every debug run since 2026-09-11, never
  under 3.5.11. The refusal was silent, so the retries were instrumented:
  every parse failure and every `saveSessionsStatsAndIndexes` refusal now logs
  its step and SQLite error. On the real transcripts the commit failed at the
  index key insert: `UNIQUE constraint failed: session_index_keys`. Those
  transcripts hold the same records twice (7 and 14 repeated message/tool IDs,
  every pair identical — Claude replays records when a session resumes), and a
  full `.replaceIdentified` rebuild inserted each ID once per copy; only
  `.update` deduplicated. Both paths now keep one row per ID (its last
  occurrence), which loses nothing because the copies are identical, and
  protects the host from any provider emitting repeated IDs. Tests:
  `SessionIndexUpdateTests.testFullReplacementWithRepeatedIDsCommitsOneRowPerID`
  and the gated `ClaudeCommitRealDataTests`, which parses and commits every
  local Claude transcript through the store's path and requires no retry.
- **Catalog v1.3.9** (`577fcbd` fix, `9ad6e0f` index): Codex 1.2.1 requiring
  API 0.5.0 replaces the rolled-back entry; Gemini stays 1.2.0. The served
  `index.json` lists it.

## Remaining work

Everything below is open, measured or reasoned, and not waived by the tests:

1. **Checkpoint state cost per append.** Now 2–4× cheaper and inside the
   sustained gate (23.6%), but still proportional to the state: 55 ms per
   append on a 24k-message session, 249 ms at 131k. The largest remaining
   part is the JSON header (two `SessionStats` with their slices). Fully
   bounded needs the per-message ledger in its own table keyed by message ID
   — an SDK checkpoint-capability and schema change.
2. **Idle CPU gate — met, 0.750%.** Task-scan resume, `memchr`, defaults
   observers acting only on change, and TelemetryDeck session stats off. That last
   one was confirmed by the owner; without it idle is ~1.07%.
3. **Archived transcript reads — done.** Streamed to a temporary file and
   paged by the session's own provider; see "Archived transcripts".
4. **Codex per-row thread deltas — measured, not worth building.** On the real
   state database (668 sessions, 669 thread rows, 20 iterations) the
   consumed-column digest costs 2.8 ms and the full metadata scan it gates
   7.9 ms (`--codex-metadata`). A per-row delta could save at most those few
   milliseconds on the rare change that does matter, at the price of a
   second, delta-merging code path to keep correct. Left as is by decision.
5. **Gemini — runtime verified** through a debug-only disabled-plugins file;
   JSON snapshots page only through the whole-parse fallback.
6. **Ship the catalog plugins — only together with a host release.** Checked
   with `nm`: the new CodexPlugin imports 81 and GeminiPlugin 79
   ClaudeStatisticsKit symbols (`TranscriptOutline`, `TranscriptByteRange`,
   `JSONMetadataReader`, `TranscriptFileReader.nextOffset`, …) that the
   installed 3.5.11 app's framework does not export. The release app reads the
   same shared plugin directory, so installing them there — or publishing them
   to the catalog for 3.5.11 users — makes those plugins fail to load and
   removes Codex/Gemini from that app. Order: publish the SDK, release a host
   linking it, then release the catalog.
   The version gate that should have caught this was stale: the new symbols
   shipped with `SDKInfo.apiVersion` still 0.4.0 and the plugins declaring
   0.4.0 (Codex) and 0.1.0 (Gemini), so a 3.5.11 host would pass its
   `minHostAPIVersion` check and fail in `dlopen`. Now `SDKInfo.apiVersion`
   is **0.5.0** and both plugins are manifest version 1.2.0 requiring 0.5.0:
   the catalog view, installer and loader of an older host skip them before
   `dlopen` ("incompatible API version"), and `release-plugins.sh` copies the
   requirement into `index.json`. Before a release, run the same `nm` check
   for every catalog plugin rebuilt against the new SDK. The fixed Codex/Gemini bundles are built and
   tested; installing them into the shared plugin directory, releasing the
   catalog and publishing the SDK are separate, authorized steps. The release
   app keeps the old plugins until then, and 3.5.11 cannot read v15-moved
   archives (it re-inlines them).
7. **Old plugins' whole results** stay unbounded by design of their API.
8. **Long-run memory — met.**
   `TranscriptNavigationMemoryRealDataTests` (gated) reopens the four largest
   local Claude transcripts (327,788,852 bytes) per round: open, jump to the
   end and the start, sweep ~30 rows through more pages than the window keeps,
   full-history search, close. Live allocator bytes after each of 30 rounds:
   47.7 MB, climbing to 54.5 MB by round 17, then **54.4–54.6 MB for the last
   14 rounds** — a warm-up that fills and stops, not sustained growth. The
   window never held more than 12 pages. (A 14-round run: 49.2 → 54.2 MB.)
   What makes up the ~6 MB warm-up was not broken down by class: the heap
   snapshots aimed at the test host caught a short-lived launcher process.
   `leaks` on the debug app after 2 d 20 h: 289 leaks, 14 KB, all in a system
   XPC connection (LinkServices), none in app code.
   The same debug process (up 2 d 20 h, Codex and Claude stores loaded, other
   agent sessions active), heap-sampled every 10 min for an hour from
   01:28:42Z: live malloc **85.13 → 84.57 MB**, no class changing by 100 KB
   or more between the first and last sample; physical footprint moved
   between 122 and 139 MB (page reuse, not live allocations). Its footprint
   had risen from 53.8 MB after launch to ~150 MB — most of it the Claude
   store started in that process on day 3 (its full parse set the 395 MB
   lifetime peak) plus allocator pages kept after that peak. No live-bytes
   sample exists from launch, so that split is inferred, not measured.
