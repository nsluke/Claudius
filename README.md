# Claudius

A macOS menu bar app that tracks your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) usage in real time — tokens, cost, and messages — with optional [Tidbyt](https://tidbyt.com) display integration.

<!-- Screenshots — replace these paths with actual images -->
<!-- ![Menu Bar](screenshots/menubar.png) -->
<!-- ![Dashboard](screenshots/dashboard.png) -->
<!-- ![Tidbyt Display](screenshots/tidbyt.png) -->

## Features

- **Menu bar at a glance** — current cost displayed right in your menu bar
- **Dashboard window** — token count, estimated cost, message count, and progress bars against your plan limits
- **5-hour rolling window** — matches Anthropic's rate limit window; shows time until reset
- **Plan presets** — select Claude Pro, Max 5x, or Max 20x to auto-set limits
- **Cost estimation** — calculates spend using Anthropic's published per-token pricing (Sonnet and Opus)
- **Tidbyt integration** — push a live usage display to your Tidbyt LED device (optional)
- **Fully local** — reads Claude Code's JSONL session logs from `~/.claude/projects/`; no network calls except the optional Tidbyt push
- **Background sync** — refreshes every 15 minutes automatically

## Requirements

- **macOS 15+** (Sequoia)
- **Claude Code** installed and used at least once (so session logs exist)
- **Tidbyt device + [Pixlet CLI](https://github.com/tidbyt/pixlet)** — only needed if you want the Tidbyt display; the app works fine without it

## Installation

### Build from source

```bash
git clone https://github.com/nsluke/Claudius.git
cd Claudius
open Claudius.xcodeproj
```

Build and run in Xcode (Cmd+R). The app will appear in your menu bar.

> **Note:** You'll need to set your own development team in Xcode under Signing & Capabilities before building.

### Download

Grab the `.dmg` from the [Releases](https://github.com/nsluke/Claudius/releases) page, open it, and drag Claudius to your Applications folder.

> **Gatekeeper note:** Since the app is not notarized, macOS will block it on first launch. Right-click (or Control-click) the app and choose **Open**, then click **Open** in the dialog. You only need to do this once.

## Setup

1. **Launch Claudius** — it immediately reads your local Claude Code logs and shows usage in the menu bar
2. **Open Settings** (gear icon or menu bar > Settings) and pick your subscription plan:
   - **Claude Pro** — 44k token / $5 cost limit
   - **Max 5x** — 88k token / $25 cost limit
   - **Max 20x** — 220k token / $100 cost limit
   - **Manual** — set your own limits
3. **(Optional) Tidbyt** — enter your Tidbyt API token and Device ID in Settings, then hit "Save & Sync Now"

## How It Works

Anthropic doesn't provide an API for tracking usage limits yet, so we've got to do some weird hacking to get around it.

Claudius reads the JSONL session logs that Claude Code writes to `~/.claude/projects/`. For each assistant message within the last 5 hours, it extracts token usage (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`) and groups messages by session.

To avoid double-counting the growing conversation context sent with every API call, Claudius uses a **conversation-peak** strategy: for each active session, only the latest turn's token count is used (since it encompasses all prior context). The peaks are then summed across sessions.

Cost is estimated using Anthropic's published per-token rates for Sonnet and Opus models.

## Tidbyt Display

If you own a [Tidbyt](https://tidbyt.com), Claudius can push a live usage widget showing cost and token progress bars. You'll need:

1. [Pixlet CLI](https://github.com/tidbyt/pixlet) installed (`brew install tidbyt/homebrew-tidbyt/pixlet`)
2. Your Tidbyt API token (from the Tidbyt mobile app)
3. Your Tidbyt Device ID

The display shows two progress bars — cost (orange) and tokens (green) — that turn red when you're over 90% of your limit.

## Project Structure

```
Claudius/
├── ClaudiusApp.swift       # App entry point, menu bar scene, AppState manager
├── UsageView.swift         # Dashboard window with metrics and progress bars
├── SettingsView.swift      # Settings UI, plan selection, Tidbyt credentials
├── TidbytManager.swift     # JSONL log parsing, cost calculation, Pixlet integration
├── KeychainHelper.swift    # Secure storage for Tidbyt API token
├── UsageStats.swift        # Data model for usage stats
├── claude_usage.star       # Pixlet Starlark script for Tidbyt rendering
└── Assets.xcassets/        # App icon and colors
```

## Contributing

Contributions welcome! Open an issue or submit a pull request.

## License

[MIT](LICENSE)
