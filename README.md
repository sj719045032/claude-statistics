# Claude Statistics

A native macOS menu bar app for monitoring your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) usage, session history, and cost statistics in real time.

<!-- TODO: Add screenshots -->

## Features

### Sessions

- **Session list** with search, sort, and batch selection/deletion
- Displays project directory, topic summary, model badge, message count, token count, and estimated cost per session
- **Session detail view** with full cost breakdown (input, output, cache write 5m/1h, cache read), token distribution bar chart, message stats (user vs. assistant), and tool usage ranking
- Resume any session directly in iTerm from the app
- Real-time updates via macOS FSEvents file watching -- new or modified sessions appear automatically

### Statistics

- **All-time summary**: total cost, sessions, tokens, messages
- **Period-based aggregation**: switch between Daily / Weekly / Monthly views
- Interactive cost bar chart with drill-down into period details
- Per-period model breakdown with cost and session count
- Cache token breakdown (5-min write, 1-hour write, cache read)

### Usage (Subscription)

- Fetches Claude subscription usage from the Anthropic OAuth API
- Displays **5-hour** and **7-day** rate limit utilization with progress bars and reset countdowns
- Per-model windows (Opus, Sonnet) when available
- Extra Usage credit tracking (used / monthly limit)
- Auto-refresh support with configurable interval

### Settings

- Auto-refresh toggle with interval selection (2 / 5 / 10 / 30 min)
- **Model pricing management**: view and edit per-model pricing, fetch latest pricing from Anthropic docs
- OAuth token status detection (reads from macOS Keychain or `~/.claude/.credentials.json`)
- Customizable tab order (drag to reorder Sessions, Stats, Usage, Settings tabs)

## Requirements

- macOS 14.0+
- Xcode 16.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Installation & Build

```bash
# Clone the repository
git clone https://github.com/user/claude-statistics.git
cd claude-statistics

# Generate Xcode project
xcodegen generate

# Open in Xcode
open ClaudeStatistics.xcodeproj

# Build and run (Cmd+R)
```

## How It Works

Claude Statistics reads data from two sources:

1. **Local session data** -- parses JSONL transcript files from `~/.claude/projects/` to extract session metadata, token counts, model info, tool usage, and timestamps. Cost is estimated using built-in model pricing tables (configurable in `~/.claude-statistics/pricing.json`).

2. **Anthropic OAuth API** -- fetches your subscription rate limit utilization (5-hour / 7-day windows) using the OAuth token stored in your macOS Keychain or `~/.claude/.credentials.json` (written by Claude Code during login).

All data is processed locally. No data is sent to any third-party service.

## Architecture

```
ClaudeStatistics/
├── App/                    # App entry point, Info.plist, entitlements
├── Models/                 # Session, SessionStats, ModelPricing
├── ViewModels/             # SessionViewModel, StatisticsViewModel, UsageViewModel
├── Views/                  # MenuBarView, SessionListView, SessionDetailView,
│                           # StatisticsView, UsageView, SettingsView
├── Services/               # SessionDataStore, FSEventsWatcher, TranscriptParser,
│                           # SessionScanner, CredentialService, PricingFetchService
└── Utilities/              # TimeFormatter, TerminalLauncher
```

- **MVVM pattern** -- Views observe published properties on ViewModels; ViewModels coordinate with Services
- **SessionDataStore** -- central data hub that scans sessions, parses transcripts (quick pass + full parse), buckets stats by period, and manages the parsed cache
- **FSEventsWatcher** -- monitors `~/.claude/projects/` via macOS FSEvents API with debounced callbacks; dirty sessions are re-parsed when the popover opens
- **TranscriptParser** -- two-pass parsing: quick stats (topic, model, message count) for the session list, and full stats (tokens, cost, tool usage) on demand
- **ModelPricing** -- configurable pricing table with built-in defaults; persisted to `~/.claude-statistics/pricing.json`; supports remote fetch from Anthropic docs

## Configuration

Model pricing is stored in `~/.claude-statistics/pricing.json` and can be edited manually or updated from the Settings tab. The file is created automatically on first launch with built-in defaults.

Settings available in the app:

| Setting | Description |
|---------|-------------|
| Auto Refresh | Periodically refresh subscription usage data |
| Refresh Interval | 2 / 5 / 10 / 30 minutes |
| Model Pricing | View, edit, or fetch latest pricing per model |
| Tab Order | Reorder the four main tabs |

## License

MIT
