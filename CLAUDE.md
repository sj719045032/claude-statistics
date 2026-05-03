# Claude Statistics — Development Guide

## Local Debug Build & Test

```bash
bash scripts/run-debug.sh
```

This script handles everything: kills old instances, cleans stale DerivedData builds, builds debug, re-registers with Launch Services, and launches by full path.

It also tries to provision a local self-signed code-signing identity named
`Claude Statistics Debug Code Signing` via `scripts/ensure-debug-codesign.sh`
when missing, so the Debug app can keep a stable TCC identity across rebuilds.

**IMPORTANT:** Always use this script to build and run. Do NOT use `open -a` or build to default DerivedData — multiple registered `.app` bundles with the same bundle ID cause Launch Services conflicts and the app won't appear in the menu bar.

**IMPORTANT:** Only use `/tmp/claude-stats-build` as the derivedDataPath for debug builds. Never use the default Xcode DerivedData path. If conflicts occur, clean up with:
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeStatistics-*/Build/Products/Debug/Claude\ Statistics.app
```

## Running Tests

```bash
bash scripts/run-tests.sh
```

**IMPORTANT:** Never run raw `xcodebuild test ...` without `PRODUCT_BUNDLE_IDENTIFIER=com.tinystone.ClaudeStatistics.debug` overriding the default. The project's default bundle ID is `com.tinystone.ClaudeStatistics` — same as the installed Release app. `xcodebuild test` on macOS launches the host app (XCTest injects into it), so the raw command wakes up / re-registers over the Release `/Applications/Claude Statistics.app`. Use this script (or copy its override) instead. The script also `lsregister -u`'s the test bundle afterwards so Launch Services doesn't keep a stale `/tmp` pointer.

## Provider Code Organization

The app supports three providers (Claude / Codex / Gemini). Provider-specific
behaviour lives under `ClaudeStatistics/Providers/<Provider>/`; cross-provider
logic lives in shared files (`Models/`, `NotchNotifications/Core/`, etc.).

**Rule of thumb — per-provider data, shared behaviour:**

- **Provider-owned**: any alias table, format quirk, schema hook, or mapping
  that only one provider cares about. Example: each provider's raw tool
  names → canonical names live in a `<Provider>ToolNames` enum inside
  `Providers/<Provider>/<Provider>Provider.swift` (e.g. `CodexToolNames`
  for `apply_patch` / `exec_command`, `GeminiToolNames` for
  `run_shell_command` / `read_file`), and are exposed to shared code
  through `ProviderDescriptor.resolveToolAlias`.
- **Shared/common**: how the canonical vocabulary gets rendered.
  `CanonicalToolName.displayName(for:)` ("edit" → "Edit", "bash" → "Bash")
  lives in `Plugins/Sources/ClaudeStatisticsKit/CanonicalToolName.swift`.
  The canonical vocabulary itself isn't a central list — each provider's
  alias table contributes the values it maps to, and the SDK consumes
  whatever shows up.
- **Dispatcher**: `ProviderKind.canonicalToolName(_:)` picks the right
  provider's alias table from `self`. Callers with a `ProviderKind` in
  scope use that; host callers without one use
  `HostCanonicalToolName.resolve(_:)` (walks all builtin providers); SDK
  callers use `CanonicalToolName.resolve(_:descriptors:)` directly with
  whatever descriptor set is in scope.

**Never** put Codex-only or Gemini-only constants inside shared files (e.g.
`ToolActivityFormatter`). Adding a new alias should touch exactly one
provider file; adding a new canonical verb touches `Models/ProviderKind.swift`
plus any `switch` case that branches on it.

When you catch yourself writing `switch providerName { case "apply_patch": … }`
inside shared code, stop — route it through a provider-owned alias table and
have the shared code switch on the canonical value instead.

## Plugin Architecture — North Star

See `docs/PLUGIN_ARCHITECTURE.md` for the full nailing-down. Three
sentences:

1. **Plugins are self-contained.** Business logic, state, provider-
   specific data models, provider-specific SwiftUI views — all live
   inside the `.csplugin`. Plugins never depend on host-module types.
2. **Host is the chassis.** It ships SDK protocols + general-purpose
   helpers + the unified UI containers (Settings tabs, Marketplace,
   notch shell, statistics scaffolding). No plugin should require
   "the host adds a new file specifically for me" to work.
3. **Cut slots, not relationships.** The chassis defines SDK
   protocols that hand plugins a SwiftUI slot to fill (via `AnyView`)
   plus a context object carrying whatever data / callbacks the
   plugin needs. Adding a third-party provider plugin must require
   zero host code changes.

**Anti-pattern to refuse**: writing a host file like
`<X>ProviderAccountCardSupplement.swift` to glue a new plugin into
host UI. If you reach for this, stop — the SDK is missing a slot.
Add the slot protocol instead, then have the plugin fill it.

## Implementation Discipline

**Build tools, not patches.** When the same shape of work shows up in
more than one place — same string cleanup, same state check, same
event handler — factor it into a named tool *before* adding the
second copy. Don't fix a parsing bug in three providers by pasting
three copies of the same `if`; build one function and call it three
times.

**Plan the interface before sprinkling call sites.** For any new
cross-cutting need ("filter junk titles", "detect a modifier combo",
"format a tool name"), decide up front: where does it live, what's
it called, what's the signature. Thread it through every call site
in the same change. Discovering the same need a second time and
bolting it on again is a smell — stop and refactor instead of adding
a fourth special case.

**Where things live:**

- Cross-provider shared behaviour (parsing, sanitizing, formatting)
  → SDK (`Plugins/Sources/ClaudeStatisticsKit/`). Examples:
  `TitleSanitizer`, `CanonicalToolName`, `SessionQuickStats`.
- Cross-view UI state / monitors → `ClaudeStatistics/Utilities/` for
  the state + storage, plus a reusable component under
  `ClaudeStatistics/Views/` for the UI. Example:
  `SkipConfirmKeyMonitor` + `SkipConfirmShortcut` (state + storage),
  `ModifierRecorderRow` (UI).
- Provider-specific quirks → the provider's own folder, behind an
  alias table or hook (see *Provider Code Organization* above).

**"Stop and factor" smells:**

- A third copy of `if text.hasPrefix("<system-reminder>")` heading
  into a third parser.
- A new `switch` on a magic string sitting in shared code.
- Two views each installing their own `NSEvent.addLocalMonitor` for
  the same key state.
- A `// TODO: also do this in CodexX` because only one provider got
  the treatment.

The answer is almost always "extract a small named tool with a clear
signature and replace every site at once" — not "drop another
special case in".

## Release a New Version

```bash
# One-command release (build → commit → publish)
bash scripts/release.sh <version>
# e.g. bash scripts/release.sh 2.10.0

# $EDITOR opens for release notes if --notes / --notes-file not given.
# Notes must be bilingual (English section + ## 中文 section).
# Pass inline:
bash scripts/release.sh 2.10.0 --notes $'## What\'s New\n- ...\n\n## 中文\n- ...'
# Or from file:
bash scripts/release.sh 2.10.0 --notes-file /tmp/notes.md
```

The script handles all steps automatically:
1. Runs `build-dmg.sh` (builds Release app, creates DMG + ZIP, generates Sparkle deltas + appcast.xml)
2. Commits `appcast.xml`, `project.pbxproj`, `project.yml` and pushes
3. Switches to `sj719045032`, creates the GitHub release with all assets, switches back

**Notes:**
- GitHub release is published under `sj719045032` account (repo owner)
- DMG is not Apple signed/notarized. Users run: `xattr -cr /Applications/Claude\ Statistics.app`
- **Release notes must be bilingual**: English section followed by `## 中文` section. Applies to every release.

### Incremental (delta) updates

`build-dmg.sh` runs Sparkle's `generate_appcast` against `build/releases-archive/`,
which keeps the last few shipped ZIPs. Delta files are generated against every
prior version still in that directory (capped by `--maximum-deltas 3`). Sparkle
clients pick the right delta automatically and fall back to the full ZIP if no
match exists.

- **Version numbers must be pure dotted numeric** (`2.9.1`, `2.10.0`). Sparkle's
  `CFBundleVersion` comparison won't rank versions with hyphen/suffix (e.g.
  `2.9.0-beta`) — `generate_appcast` silently skips delta generation when
  versions are unrankable.
- Keep the last 2–3 shipped ZIPs in `build/releases-archive/` — deleting them
  means the next release has no base to diff against, users fall back to the
  full download. The directory is gitignored (`build/`); re-download from
  GitHub releases if you're on a fresh checkout:
  ```bash
  mkdir -p build/releases-archive
  curl -L -o "build/releases-archive/ClaudeStatistics-<prev>.zip" \
    https://github.com/sj719045032/claude-statistics/releases/download/v<prev>/ClaudeStatistics-<prev>.zip
  ```
- Delta filenames look like `Claude Statistics2.9.1-2.9.0.delta` (no space in
  the middle — Sparkle's naming). They all need to be uploaded to the
  v<version> GitHub release because the appcast's `--download-url-prefix`
  points at that single tag. The script prints a ready-to-paste
  `gh release create` command at the end with all required assets.
- `generate_appcast` needs the `ed25519` private key in the macOS keychain
  (same one `sign_update` uses).
- Measured: 12 MB → few KB for no-code-change diff; real point releases
  typically land at single-digit MB deltas.

### Releasing the SDK (xcframework)

The SDK (`ClaudeStatisticsKit`) ships to third-party plugin authors as
an `.xcframework` referenced via SwiftPM `.binaryTarget(url:, checksum:)`
from `Package.swift` at repo root. SDK versions are independent of host
app versions — bump them only when SDK ABI changes.

#### SDK source mode is automatic

`Package.swift` and `build/catalog-repo/project.yml` carry an
`SDK_MODE_BEGIN` / `SDK_MODE_END` block managed by
`scripts/sdk-mode.sh`. You do **not** flip it by hand:

- `scripts/run-debug.sh` calls `sdk-mode.sh local` at the top, so
  any local rebuild + `dev-install.sh` of a catalog plugin links
  the in-progress SDK source.
- `scripts/release.sh` calls `sdk-mode.sh published` before its
  build/commit step, so what gets pushed always cites the published
  sdk-v<x.y.z> URL+checksum (catalog-repo branch:main).
- Both invocations short-circuit when the file is already in the
  target mode (no diff, no mtime change, no SwiftPM re-resolve).

Run `bash scripts/sdk-mode.sh` (no args) to confirm where the two
files currently point. Manual `sdk-mode.sh local|published` is only
needed for ad-hoc workflows, e.g. building the xcframework outside
of `release.sh` (see below). Don't remove the marker comments — the
script depends on them.

#### Local SDK iteration (typical loop)

```bash
# 1. Edit Plugins/Sources/ClaudeStatisticsKit/*.swift.

# 2. Rebuild the xcframework so catalog plugins see the changes.
bash scripts/build-xcframework.sh

# 3. dev-install the affected catalog plugins.
cd build/catalog-repo
bash scripts/dev-install.sh KittyPlugin
bash scripts/dev-install.sh GhosttyPlugin   # etc.
cd -

# 4. Relaunch the host (also pins SDK references at local).
bash scripts/run-debug.sh
```

#### Publishing a new sdk-v<x.y.z>

```bash
# 1. Make sure both files quote the published refs and smoke-build.
bash scripts/sdk-mode.sh published
bash scripts/run-debug.sh    # flips back to local; that's fine

# 2. Build the xcframework. (sdk-mode.sh state doesn't matter for
#    build-xcframework — it archives source either way.)
bash scripts/sdk-mode.sh published
bash scripts/build-xcframework.sh
# Copy the printed SwiftPM checksum.

# 3. Update PUBLISHED_SDK_TAG / PUBLISHED_SDK_CHECKSUM in
#    scripts/sdk-mode.sh and the matching url/checksum literals in
#    the Package.swift SDK_MODE_BEGIN/END block. Re-run
#    `bash scripts/sdk-mode.sh published` to make sure both files
#    end up quoting the new tag.

# 4. Create the sdk-v<x.y.z> GitHub release.
gh auth switch --hostname github.com --user sj719045032
gh release create sdk-v<x.y.z> \
    build/xcframework/ClaudeStatisticsKit.xcframework.zip \
    --repo https://github.com/sj719045032/claude-statistics \
    --title "ClaudeStatisticsKit SDK v<x.y.z>" \
    --notes "..."
gh auth switch --hostname github.com --user tinystone007

# 5. Commit + push Package.swift / scripts/sdk-mode.sh.
```

The catalog repo's `project.yml` references the SDK as
`packages.ClaudeStatisticsKit.url: https://github.com/sj719045032/claude-statistics, branch: main`,
so as soon as Package.swift is pushed every plugin in the catalog
picks up the new SDK on its next build.

### Marketplace plugin artifacts

Plugin bundles do **not** ship from this repo — they live in
**`github.com/sj719045032/claude-statistics-plugins`** (the catalog
repo). The catalog repo owns both `index.json` metadata and the
`.csplugin.zip` bytes; `PluginCatalogEntry.downloadURL` points at
that repo's own GitHub releases. The host's
`PluginCatalog.defaultRemoteURL` is set to
`https://raw.githubusercontent.com/sj719045032/claude-statistics-plugins/main/index.json`.

The catalog repo has its own build + release workflow (see its
README and `scripts/`). When you bump the SDK in this repo (above),
the catalog repo just needs to rebuild + repack its plugins so they
link the new SDK; the catalog operator runs the catalog repo's
release script. Apple Terminal is the one chassis built-in terminal
plugin (system-bundled with macOS, lives in
`ClaudeStatistics/Terminal/Capabilities/AppleTerminalBuiltin.swift`);
every other plugin is installed at runtime via Settings → Plugins
→ Discover.

## Deploy Website to Vercel

The marketing site is deployed from the **repo root**, not from `website/`.

```bash
# 1. Build locally first
cd /path/to/claude-statistics/website
ASTRO_TELEMETRY_DISABLED=1 npm run build

# 2. Go back to repo root
cd /path/to/claude-statistics

# 3. Link to the existing Vercel project if needed
npx vercel link --project claude-statistics --yes

# 4. Deploy production from repo root
npx vercel --prod --yes
```

**Important:**
- Do **not** run `vercel link` or `vercel --prod` inside `website/`, or Vercel may create/link a separate project such as `website`.
- The root `vercel.json` already points Vercel at the Astro app with:
  - `installCommand: npm --prefix website install`
  - `buildCommand: npm --prefix website run build`
  - `outputDirectory: website/dist`
- The intended Vercel project is `jinshitinystone-9840s-projects/claude-statistics`.
- If Vercel fails with missing files under `website/public/*.symlink.bak`, remove those backup symlinks before redeploying.
