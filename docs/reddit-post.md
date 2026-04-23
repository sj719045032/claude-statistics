# Reddit Post — r/ClaudeAI

> **2026-04-23 · v3.1.0 update**
>
> Original post reflected the early Claude-only version. Current Claude Statistics has grown into a control center for the whole AI-coding terminal ecosystem. Recent additions:
>
> - **Notch Island** — live activity surface docked to the MacBook notch showing every running Claude Code / Codex / Gemini session; inline Allow / Deny permission cards; waiting-input pulses; one-keystroke focus return into the exact terminal tab.
> - **Ghostty tab-accurate focus** — clicking a session card lands on the exact Ghostty tab the session is running in, even when multiple sessions share the same project directory (surface id → window+tab → cwd fallbacks).
> - **Multi-provider menu bar strip** — the menu bar shows every enabled provider (Claude / Codex / Gemini) side by side: icon + rotating window/quota usage, colour-coded at 50% / 80% consumed.
> - **Gemini OAuth auto-refresh + Swift HookCLI** — stability + faster startup.
>
> Body below is the original post; for the current feature list refer to README.

## Title

I built a macOS menu bar app to track Claude Code sessions, token usage, and costs in real time

## Body

I've been using Claude Code heavily for the past few months and kept running into the same frustrations:

- **No idea how much I'm actually spending** — tokens add up fast across sessions and I had no visibility into where the cost was going
- **Rate limit surprises** — hitting the 5-hour or 7-day cap without warning
- **No way to review past sessions** — which project burned through the most tokens? What model was I using?

So I built **Claude Statistics** — a native macOS menu bar app that answers all of these questions.

## What it does

📊 **Statistics** — Daily/weekly/monthly/yearly cost and token breakdowns with interactive charts. Drill into any period to see exactly where your spend went.

💬 **Session Management** — Auto-discovers all your Claude Code sessions from `~/.claude/projects/`. Search, browse, and view full transcripts with tool call details.

⚡ **Usage Monitoring** — Live subscription usage (5h / 7d windows) pulled from Anthropic's API. See your rate limit utilization at a glance with reset countdowns.

🔒 **100% Local** — All parsing happens on your machine. Nothing is uploaded anywhere. It just reads your local JSONL transcripts and your existing OAuth token.

## Some details

- Native SwiftUI + AppKit, lives in your menu bar (no dock icon)
- Supports Opus / Sonnet / Haiku with per-model cost breakdowns
- Multi-model sessions are handled correctly
- Built-in transcript viewer with full-text search
- Resume or start new Claude Code sessions directly from the app
- Customizable model pricing
- Auto-updates via Sparkle
- Open source (MIT)

## Links

- GitHub: https://github.com/sj719045032/claude-statistics
- Download DMG: https://github.com/sj719045032/claude-statistics/releases

Requires macOS 14+. The app is not notarized, so you may need to run `xattr -cr /Applications/Claude\ Statistics.app` on first launch.

Would love to hear feedback or feature requests!
