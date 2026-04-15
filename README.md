# Claude Statistics

**[中文文档](docs/README_zh.md)**

A native macOS menu bar app for monitoring your [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex CLI](https://github.com/openai/codex), and Gemini CLI sessions, subscription usage, and token/cost analytics in real time.

## v2.5.0 Highlights

- **Shareable stat cards** — generate beautiful, persona-driven share images with role scoring, badges, and proof metrics based on your session data
- **Enhanced language support** — expanded localization coverage with refined language switching and multi-language string management
- **Improved menu bar view** — better session statistics display with richer inline information
- **Statistics view refinements** — cleaner period summaries with enhanced token and cost presentation

![Claude Statistics overview](docs/screenshots/hero-overview.png)

## Screenshots

### Conversation & Detail

| Session Detail | Transcript Search |
|---|---|
| ![Session detail](docs/screenshots/session-detail.png) | ![Transcript search](docs/screenshots/transcript-search.png) |

### Statistics

| Overview | Period Detail |
|---|---|
| ![Statistics overview](docs/screenshots/statistics-overview.png) | ![Statistics detail](docs/screenshots/statistics-detail.png) |

### Usage

![Usage hover](docs/screenshots/usage-hover.png)

## Features

### Menu Bar Workflow

Claude Statistics lives in your macOS menu bar and opens as a floating panel.

- Native **NSStatusItem + floating panel** experience
- Reactive menu bar status text based on subscription usage
- Fast access to Sessions, Stats, Usage, and Settings from one compact panel
- No dock icon — built as a lightweight menu bar utility

### Session Management

Claude Statistics automatically discovers and parses sessions from `~/.claude/projects/` (Claude Code), `~/.codex/projects/` (Codex CLI), and `~/.gemini/tmp/` (Gemini CLI). Each provider keeps its own parsing pipeline and local cache, so switching providers does not stop background indexing for the others.

**Session List**

- Search by project path, topic, session name, or session ID
- Recent sessions section for quick access
- Grouped by project directory with expandable/collapsible sections
- Each session shows topic/title, model badge, message count, token count, cost, context usage, and timestamp
- Model-aware color badges (Opus / Sonnet / Haiku)
- Batch selection mode for bulk deletion
- Real-time updates via macOS file watching where available, with provider-specific rescans for formats that need it
- Quick actions on hover: new session, resume session, open transcript, delete, copy path

**Session Detail**

- Per-session overview: model, duration, file size, start/end time
- Accurate token accounting: input, output, cache write, cache read
- Multi-model cost breakdown with per-model token usage
- Context window utilization percentage and visual indicators
- Token distribution bar with cache breakdown
- Tool usage ranking with animated progress bars
- Trend chart for session activity over time

**Session Actions**

- Resume any session in your preferred terminal
- Start a new Claude Code session in the same project
- Delete individual or multiple sessions with confirmation
- Copy session path / identifiers quickly

### Transcript Viewer & Search

Built-in transcript browsing for full conversation history.

- Full transcript viewer inside the app
- Search across conversation content and tool calls
- Match navigation (previous / next)
- Search result highlighting inside markdown content
- Dedicated rendering for tool calls, tool details, and message roles
- Markdown rendering with code block support
- Better visibility into Claude tool activity inside each session

### Statistics & Cost Analytics

Analyze usage from the local transcript data you already have.

- All-time summary: total cost, sessions, tokens, messages
- Period-based aggregation: **Daily / Weekly / Monthly / Yearly**
- Interactive cost bar chart with drill-down into period detail
- Period detail pages with overview, trend chart, token distribution, and model breakdown
- Cache token breakdown (5-minute write, 1-hour write, cache read)
- Period list optimized for fast scanning of cost and token-heavy windows
- All-time summary is computed from parsed sessions directly, so it stays stable across period switches

### Subscription Usage Monitoring

Fetches provider-specific live usage data and combines it with local session analytics.

- Claude: 5-hour and 7-day windows with utilization, reset countdown, and per-model windows when available
- Gemini: grouped quota buckets (Pro / Flash / Flash Lite) with reset countdown and local token trend charts
- Menu bar usage text adapts to the active provider's best metric
- Extra Usage credit tracking when available
- Usage trend chart with cumulative token and cost view
- Interpolated tooltip + crosshair for chart inspection
- Animated progress bars for rate-limit usage
- Error banner with retry action and direct dashboard link when supported
- Configurable auto-refresh interval

### Provider Switcher

A compact switcher in the footer lets you toggle between providers at any time:

- **Claude Code** — reads `~/.claude/projects/`, fetches usage from Anthropic's OAuth API
- **Codex CLI** — reads `~/.codex/projects/`, decodes profile from local JWT
- **Gemini CLI** — reads `~/.gemini/tmp/`, fetches usage from Gemini API, and exposes provider-specific grouped usage/trend views

Providers that are not installed are hidden or disabled automatically depending on the current control.

### Settings & Integrations

- Launch at login
- Preferred terminal selection:
  - Auto
  - Ghostty
  - Terminal.app
  - iTerm2
  - Warp
  - Kitty
  - Alacritty
- Language selection: Auto / English / Simplified Chinese
- Font scale control
- Custom tab ordering
- Model pricing management (view, edit, fetch latest pricing)
- Status line integration for Claude Code, Codex CLI, and Gemini CLI
- OAuth token detection from macOS Keychain or `~/.claude/.credentials.json`
- Diagnostics log export
- Sparkle-based in-app update checks

### Share Cards

Generate beautiful, shareable stat cards from your session analytics.

- **Persona-driven roles** — 10 unique share roles (Vibe Coding King, Tool Summoner, Night Shift Engineer, etc.) with themed gradients, SF Symbols artwork, and mascot scenes
- **Achievement badges** — 11 unlockable badges across categories like schedule, context, model preference, tooling, cost efficiency, and burst usage
- **Proof metrics** — data-backed evidence showing your top stats (token counts, session counts, tool usage, cost efficiency)
- **QR code integration** — each card includes a QR code for sharing or quick access
- **Export as PNG** — render and save share cards at native resolution for social media or messaging

### UI & Interaction Details

- Material-based cards with consistent design tokens (`Theme.swift`)
- Hover scale animation for clickable icon buttons
- Sliding capsule indicators for tab and period selection
- Chevron rotation and push transitions for expandable groups
- Chart reveal animation from left to right
- Staggered list entry animations in statistics views
- Improved hover feedback in session and statistics rows

## Requirements

- macOS 14.0+
- Xcode 16.0+ (for local development)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (to generate the project from `project.yml`)

## Installation

### Download DMG (Recommended)

Download the latest `.dmg` from [Releases](https://github.com/sj719045032/claude-statistics/releases), open it, and drag **Claude Statistics** into **Applications**.

Because the app is not notarized by Apple, macOS may block the first launch. If that happens:

```bash
xattr -cr /Applications/Claude\ Statistics.app
```

Or right-click the app → **Open** → confirm **Open** in the dialog.

### Build from Source

```bash
# Clone the repository
git clone https://github.com/sj719045032/claude-statistics.git
cd claude-statistics

# Generate Xcode project
xcodegen generate

# Open in Xcode
open ClaudeStatistics.xcodeproj
```

For local debug runs, use the provided script:

```bash
bash scripts/run-debug.sh
```

This script builds using the dedicated debug DerivedData path and relaunches the menu bar app safely.

## How It Works

Claude Statistics supports three providers, each with its own local-first data sources:

**Claude Code**
- Parses JSONL transcript files under `~/.claude/projects/`
- Extracts session metadata, timestamps, token counts, model usage, tool calls, and cost estimates
- Uses built-in model pricing tables (customizable via settings / pricing file)
- Fetches subscription usage windows from Anthropic's OAuth-backed API (5h / 7d / per-model)

**Codex CLI**
- Parses conversation files under `~/.codex/projects/`
- Decodes user profile (name, email, plan) from a local JWT — no extra API calls
- Session scanning, transcript parsing, and lightweight search indexing adapted for Codex's file format

**Gemini CLI**
- Parses JSON transcript files under `~/.gemini/tmp/` and project roots from `~/.gemini/history/`
- Extracts session history, token counts, model usage, and provider-specific grouped usage windows
- Keeps the latest snapshot when Gemini writes multiple files for the same logical session
- Uses lightweight search indexing and provider-specific usage/menu bar presentation

All parsing and analytics happen locally on your machine.

## Architecture

```text
ClaudeStatistics/
├── App/                    # App entry, status bar controller, floating panel
├── Models/                 # Session, SessionStats, AggregateStats, UsageData, ShareRole, ShareMetrics, etc.
├── Providers/              # SessionProvider protocol + Claude, Codex, and Gemini implementations
│   ├── SessionProvider.swift
│   ├── Claude/             # ClaudeProvider, ClaudeSessionScanner, ClaudeTranscriptParser
│   ├── Codex/              # CodexProvider, CodexSessionScanner, CodexTranscriptParser
│   └── Gemini/             # GeminiProvider, GeminiSessionScanner, GeminiTranscriptParser
├── Services/               # Parsing, scanning, storage, pricing fetch, usage API, share metrics builder, logs
├── Utilities/              # Terminal launching, time formatting, language handling, share image exporter
├── ViewModels/             # SessionViewModel, UsageViewModel, ProfileViewModel
├── Views/                  # Sessions, statistics, usage, transcript, settings, theme, share cards
├── Resources/              # Localizable strings and assets
└── scripts/                # Debug build/run and DMG release helpers
```

Notable implementation details:

- SwiftUI + AppKit hybrid architecture
- `NSStatusItem` for menu bar presence
- Custom floating panel managed by `StatusBarController`
- `Theme.swift` design-token layer for shared styling and animation
- Sparkle for in-app updates

## Build & Release

### Debug Run

```bash
bash scripts/run-debug.sh
```

This script:

1. Kills older app instances
2. Cleans stale debug builds
3. Builds with the dedicated `/tmp/claude-stats-build` DerivedData path
4. Re-registers the app with Launch Services
5. Launches the fresh binary directly

### Build DMG

```bash
bash scripts/build-dmg.sh 2.0.0
# Output: build/ClaudeStatistics-2.0.0.dmg
```

The script will:

1. Build a Release configuration with the specified version
2. Create a drag-to-install DMG
3. Sign the DMG with Sparkle's EdDSA key
4. Update `appcast.xml`

### Publish a Release

```bash
# 1. Commit and push appcast / version updates
git add ClaudeStatistics.xcodeproj/project.pbxproj appcast.xml
git commit -m "chore: update appcast for vX.Y.Z"
git push

# 2. Switch to the publishing account
gh auth switch --hostname github.com --user sj719045032

# 3. Create the GitHub release
gh release create vX.Y.Z build/ClaudeStatistics-X.Y.Z.dmg \
  --title "vX.Y.Z" --notes "Release notes"

# 4. Switch back if needed
gh auth switch --hostname github.com --user tinystone007
```

Existing users receive updates through Sparkle's in-app updater.

## Configuration

Model pricing is stored in `~/.claude-statistics/pricing.json` and can be edited manually or from the Settings tab.

| Setting | Description |
|---------|-------------|
| Launch at Login | Start Claude Statistics automatically on login |
| Auto Refresh | Refresh subscription usage data on an interval |
| Preferred Terminal | Terminal app used for resuming Claude sessions |
| Model Pricing | View, edit, or fetch latest model pricing |
| Status Line | Install/update Claude Code status line integration |
| Tab Order | Reorder the main tabs |
| Language | Auto / English / Simplified Chinese |
| Font Scale | Adjust panel content scale |
| Diagnostics | Open/export app logs |

## Star History

<a href="https://www.star-history.com/?repos=sj719045032%2Fclaude-statistics&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=sj719045032/claude-statistics&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=sj719045032/claude-statistics&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=sj719045032/claude-statistics&type=date&legend=top-left" />
 </picture>
</a>

## License

MIT
