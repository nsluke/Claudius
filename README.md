# Claudius

A macOS menu bar app that shows your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) usage in real time — no setup required.

Claudius reads Claude Code's OAuth token straight from your macOS Keychain, so it works the moment you launch it. It shows the same session and weekly utilization percentages you'd see on claude.ai, right in your menu bar. Optionally, it can push a live display to a [Tidbyt](https://tidbyt.com) LED device.

| Menu Bar | Dashboard | Tidbyt |
|----------|-----------|--------|
| <img src="Claudius/screenshots/menu.png" alt="Menu Bar" width="250"> | <img src="Claudius/screenshots/dashboard.png" alt="Dashboard" width="250"> | <img src="Claudius/screenshots/tidbyt.jpg" alt="Tidbyt" width="250"> |

## How It Works

Claudius finds the OAuth token that Claude Code stores in your macOS Keychain (service `Claude Code-credentials`) and calls the Anthropic OAuth usage API every 60 seconds. The API returns your 5-hour session utilization and 7-day weekly utilization as percentages of your plan limit — the same numbers shown on the claude.ai settings page.

If the token is missing or expired, Claudius falls back to reading Claude Code's local JSONL session logs from `~/.claude/projects/` and estimating usage from raw token counts.

## Features

- **Zero-config auth** — automatically reads Claude Code's OAuth token from your Keychain; no session keys or org IDs to copy
- **Menu bar at a glance** — current session utilization percentage in the menu bar
- **Dashboard window** — 5-hour session and 7-day weekly utilization with progress bars and reset countdowns
- **Local fallback** — estimates usage from Claude Code's JSONL logs when OAuth isn't available
- **Plan presets** — select Claude Pro, Max 5x, or Max 20x to set your limits
- **Tidbyt integration** — push a live usage display to your Tidbyt LED device (optional)
- **Background sync** — refreshes every 60 seconds

## Requirements

- **macOS 15+** (Sequoia)
- **Claude Code** installed and logged in (so the OAuth token exists in your Keychain)
- **Tidbyt device + [Pixlet CLI](https://github.com/tidbyt/pixlet)** — only needed for the Tidbyt display

## Installation

### Download

Grab the `.dmg` from the [Releases](https://github.com/nsluke/Claudius/releases) page, open it, and drag Claudius to your Applications folder.

> **Gatekeeper note:** Since the app is not notarized, macOS will block it on first launch. Right-click the app and choose **Open**, then click **Open** in the dialog. You only need to do this once.

### Build from source

```bash
git clone https://github.com/nsluke/Claudius.git
cd Claudius
open Claudius.xcodeproj
```

Build and run in Xcode (Cmd+R). The app appears in your menu bar.

> You'll need to set your development team in Xcode under Signing & Capabilities before building.

## Setup

### Usage tracking (automatic)

1. Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and log in to your claude.ai account
2. Launch Claudius — it finds the OAuth token automatically
3. Pick your subscription plan in Settings (Pro, Max 5x, or Max 20x)

That's it. No browser DevTools, no cookies, no org IDs.

### Tidbyt (optional)

1. Install [Pixlet CLI](https://github.com/tidbyt/pixlet): `brew install tidbyt/homebrew-tidbyt/pixlet`
2. Enter your Tidbyt API token and Device ID in Settings
3. Choose a layout: Default (dual progress bars), Minimal (text only), or Graph (vertical bar chart)

## Project Structure

```
Claudius/
├── ClaudiusApp.swift            # App entry point, menu bar scene, AppState manager
├── ClaudeWebUsageService.swift  # Anthropic OAuth API integration
├── KeychainHelper.swift         # Keychain access for Claude Code OAuth token and Tidbyt credentials
├── UsageView.swift              # Dashboard window with metrics and progress bars
├── SettingsView.swift           # Settings UI, plan selection, Tidbyt config
├── TidbytManager.swift          # JSONL log parsing, cost calculation, Pixlet integration
├── UsageStats.swift             # Data model for usage stats
├── claude_usage.star            # Tidbyt default layout (dual progress bars)
├── claude_minimal.star          # Tidbyt minimal layout (text only)
├── claude_graph.star            # Tidbyt graph layout (vertical bars)
└── Assets.xcassets/             # App icon and colors
```

## Contributing

Contributions welcome! Open an issue or submit a pull request.

## License

[MIT](LICENSE)
