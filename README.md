# Claude Statistics

**[中文文档](docs/README_zh.md)**

A native macOS menu bar app for monitoring your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) usage, session history, and cost statistics in real time.

## Features

### Session Management

Claude Statistics automatically discovers and parses all your Claude Code sessions from `~/.claude/projects/`, giving you full visibility into your usage.

**Session List**

- Search sessions by project name, topic, or session ID
- Each session displays: project directory, topic summary, model badge, message count, token count, file size, and estimated cost
- Cost color coding — green (< $0.1), orange ($0.1–$1), red (> $1) — for quick scanning
- Batch selection mode: select multiple sessions and delete in bulk
- Force rescan button to re-parse all sessions on demand
- Real-time updates via macOS FSEvents — new or modified sessions appear automatically without manual refresh

**Session Detail**

- **Cost breakdown**: per-model input, output, cache write (5m/1h), cache read tokens with exact cost calculation
- **Multi-model tracking**: sessions using multiple models (e.g. Opus + Sonnet) show accurate per-model cost and token breakdown with visual progress bars
- **Context window**: usage percentage with progress bar, matching Claude Code's calculation exactly
- **Token distribution**: segmented bar chart showing input, output, and cache token proportions
- **Message stats**: total, user, and assistant message counts
- **Tool usage ranking**: all tools used in the session with call counts and progress bars
- Expandable topic and last prompt display

**Session Actions**

- **Resume** any session in your preferred terminal (Terminal.app / iTerm2 / Warp / Kitty / Alacritty)
- **New session** in the same project directory from any session
- **Delete** single or multiple sessions with confirmation dialog

### Statistics

- **All-time summary**: total cost, sessions, tokens, messages — displayed above period picker for quick reference
- **Period-based aggregation**: Daily / Weekly / Monthly / Yearly views
- Interactive cost bar chart with drill-down into period details
- Per-period model breakdown with per-model cost calculation
- Cache token breakdown (5-min write, 1-hour write, cache read)
- Unified cost & model cards with expandable detail rows

### Usage (Subscription)

- Fetches Claude subscription usage via the Anthropic OAuth API
- Displays **5-hour** and **7-day** rate limit utilization with progress bars and reset countdowns
- Per-model windows (Opus, Sonnet) when available
- Extra Usage credit tracking (used / monthly limit)
- Auto-refresh with configurable interval (5 / 10 / 30 min); the usage API is rate-limited, so a longer interval is recommended
- Menu bar status text updates reactively with usage data
- Error display with retry button and direct link to [claude.ai/settings/usage](https://claude.ai/settings/usage)

### Settings

- **Subscription usage auto-refresh** toggle with interval selection (5 / 10 / 30 min)
- **Preferred terminal** selection (Auto / Terminal / iTerm2 / Warp / Kitty / Alacritty)
- **Model pricing management**: view and edit per-model pricing, fetch latest pricing from Anthropic docs
- **Status line integration**: install/update a Claude Code status line script that shares the app's pricing and usage cache
- OAuth token status detection (reads from macOS Keychain or `~/.claude/.credentials.json`)
- Customizable tab order
- **Language selection**: Auto (follow system) / English / Simplified Chinese

## Requirements

- macOS 14.0+

## Installation

### Download DMG (Recommended)

Download the latest `.dmg` from [Releases](https://github.com/sj719045032/claude-statistics/releases), open it and drag **Claude Statistics** to the **Applications** folder.

Since the app is not notarized, macOS may block it on first launch. To fix this, run:

```bash
xattr -cr /Applications/Claude\ Statistics.app
```

Or: right-click the app → Open → click "Open" in the dialog (first launch only).

### Build from Source

Requires Xcode 16.0+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
# Clone the repository
git clone https://github.com/sj719045032/claude-statistics.git
cd claude-statistics

# Generate Xcode project
xcodegen generate

# Open in Xcode
open ClaudeStatistics.xcodeproj

# Build and run (Cmd+R)
```

To build a DMG for distribution:

```bash
./scripts/build-dmg.sh 1.1.0
# Output: build/ClaudeStatistics-1.1.0.dmg
```

## How It Works

Claude Statistics reads data from two sources:

1. **Local session data** — parses JSONL transcript files from `~/.claude/projects/` to extract session metadata, token counts, model info, tool usage, and timestamps. Streaming entries are deduplicated by message ID (last entry wins, capturing final output token counts). Cost is estimated using built-in model pricing tables (configurable in `~/.claude-statistics/pricing.json`), with per-model accuracy for multi-model sessions.

2. **Anthropic OAuth API** — fetches your subscription rate limit utilization (5-hour / 7-day windows) using the OAuth token stored in your macOS Keychain or `~/.claude/.credentials.json` (written by Claude Code during login).

All data is processed locally. No data is sent to any third-party service.

## Architecture

```
ClaudeStatistics/
├── App/                    # App entry point (MenuBarExtra), Info.plist, entitlements
├── Models/                 # Session, SessionStats, ModelPricing, AggregateStats,
│                           # TranscriptEntry
├── ViewModels/             # SessionViewModel, StatisticsViewModel, UsageViewModel
├── Views/                  # MenuBarView, SessionListView, SessionDetailView,
│                           # StatisticsView, UsageView, SettingsView
├── Services/               # SessionDataStore, FSEventsWatcher, TranscriptParser,
│                           # SessionScanner, CredentialService, PricingFetchService,
│                           # StatusLineInstaller, UsageAPIService
├── Utilities/              # TimeFormatter, TerminalLauncher, LanguageManager
└── Resources/              # Localizable.strings (en, zh-Hans)
```

## Configuration

Model pricing is stored in `~/.claude-statistics/pricing.json` and can be edited manually or updated from the Settings tab. The file is created automatically on first launch with built-in defaults.

| Setting | Description |
|---------|-------------|
| Auto Refresh | Periodically refresh subscription usage data (API is rate-limited, longer intervals recommended) |
| Refresh Interval | 5 / 10 / 30 minutes |
| Preferred Terminal | Terminal app for session resume |
| Model Pricing | View, edit, or fetch latest pricing per model |
| Status Line | Install/update integrated status line for Claude Code |
| Tab Order | Reorder the four main tabs |
| Language | Auto (system) / English / Simplified Chinese |

## License

MIT
