# Repository Guidelines

## Project Structure & Module Organization

`ClaudeStatistics/` contains the app code. Key folders are `App/` for entry and status bar wiring, `Views/` and `ViewModels/` for UI state, `Services/` for parsing/storage/update logic, `Providers/` for Claude/Codex/Gemini integrations, `Models/` for shared data types, `Utilities/` for helpers, and `Resources/` plus `Assets.xcassets/` for localized strings and images. Project generation is driven by `project.yml`, release/support scripts live in `scripts/`, the marketing site lives in `website/`, and product docs/screenshots are under `docs/`.

## Build, Test, and Development Commands

- `xcodegen generate` regenerates `ClaudeStatistics.xcodeproj` from `project.yml`.
- `bash scripts/run-debug.sh` is the required local debug path. It builds into `/tmp/claude-stats-build`, cleans stale app bundles, and relaunches the menu bar app safely.
- `xcodebuild -project ClaudeStatistics.xcodeproj -scheme ClaudeStatistics -destination 'platform=macOS' build` runs a direct build check.
- `cd website && npm install && ASTRO_TELEMETRY_DISABLED=1 npm run build` installs site dependencies and builds the multilingual Astro marketing site.
- `bash scripts/build-dmg.sh 2.7.6` creates release artifacts, signs the Sparkle ZIP, and updates `appcast.xml`.

Do not use default Xcode DerivedData for debug runs; this repository relies on the dedicated debug path to avoid Launch Services conflicts.

## Coding Style & Naming Conventions

Use Swift 5.9 with standard Xcode formatting: 4-space indentation, one primary type per file, `UpperCamelCase` for types, and `lowerCamelCase` for methods, properties, and enum cases. Keep provider-specific code inside `Providers/Claude`, `Providers/Codex`, or `Providers/Gemini`, and place shared abstractions at the `Providers/` root. Follow existing naming such as `SessionScanner`, `TranscriptParser`, and `UsageService`. The `website/` app uses Astro with Tailwind plus custom CSS; keep copy centralized and prefer reusable content structures over duplicating strings across pages.

## Testing Guidelines

There is no dedicated XCTest target in the repository today. For changes, at minimum run `bash scripts/run-debug.sh` and verify the affected flows manually in the menu bar app. If you add automated tests, mirror the source layout in a new test target and use XCTest naming like `testCodexSessionScannerParsesWalRecovery()`.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commit prefixes: `feat:`, `fix:`, and `chore:`. Keep subjects short and imperative, for example `fix: improve 7d exhaust prediction`. PRs should describe user-visible behavior, note any provider-specific impact, and include screenshots for UI changes. If you touch packaging or updates, mention `appcast.xml`, release artifacts, and version bumps explicitly.

## Contributor Notes

Read `CLAUDE.md` before changing build or release workflows. It documents the required debug script, release sequence, and account-specific GitHub release steps.
