# Claudius

A macOS menu bar app that shows your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) usage in real time.

Claudius reads your usage from whatever local source is available — the Claude desktop app's own cache, the Claude Code CLI's Keychain token, or your local session logs — so it works the moment you launch it. It shows the same utilization percentages you'd see on claude.ai — session, weekly, and any per-model cap such as Fable — right in your menu bar. Optionally, it can push a live display to a [Tidbyt](https://tidbyt.com) LED device.

> **Prerequisite:** You need [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and signed in — either through the Claude desktop app or the `claude` CLI. Claudius reads whichever one you use; with neither, it falls back to estimating from local session logs.

| Menu Bar | Dashboard | Tidbyt |
|----------|-----------|--------|
| <img src="Claudius/screenshots/menu.png" alt="Menu Bar" width="250"> | <img src="Claudius/screenshots/dashboard.png" alt="Dashboard" width="250"> | <img src="Claudius/screenshots/tidbyt.jpg" alt="Tidbyt" width="250"> |

## How It Works

Claudius reads your usage from the best source available, in this order:

1. **The Claude desktop app's usage cache** (`~/Library/Application Support/Claude/plan-usage-history.json`). The desktop app already polls your usage every ~15 minutes and caches it. Reading that file needs no token, no network request, and no Keychain access — so it can't expire, can't prompt, and can't be rate limited. If you run Claude Code through the desktop app, this is the source Claudius uses.
2. **The Anthropic OAuth usage API**, using the token the Claude Code *CLI* stores in your Keychain (service `Claude Code-credentials`). This path gives richer data — reset countdowns and per-model caps — but only applies if you actually run the CLI.
3. **Local JSONL estimates** from `~/.claude/projects/`.

> **If you use the desktop app, the CLI's Keychain item is never updated.** The desktop app keeps its credentials in its own encrypted store, so that Keychain token goes stale and stops working within hours of your last CLI use. Claudius used to depend on it exclusively, which made the app appear broken. It now prefers the desktop cache and falls back gracefully.

Claudius refreshes every 5 minutes. The API returns your usage as percentages of your plan limit — the same numbers shown on the claude.ai settings page.

Claudius renders **whatever windows the API reports**, rather than a fixed pair. Today that's typically your 5-hour session window, your 7-day weekly window, and — on accounts that have one — a separate weekly cap that applies to a single model, such as Fable. If Anthropic adds, renames, or removes a window, Claudius picks up the change without an update: unrecognized windows are labelled with the name the API gives them, and windows that disappear simply stop rendering.

### Keychain access

Claudius treats the Claude Code login token (`Claude Code-credentials`) as **strictly read-only**. It never writes to that item, and it never refreshes the token either.

Both matter. Writing is a separate Keychain permission from reading, so an "Always Allow" grant never covered it and every failed write re-prompted. And refresh tokens are single-use with rotation — if Claudius redeemed one, Claude Code would be left holding a dead token, breaking the login Claudius depends on. Refreshing is Claude Code's job; Claudius just reads the access token and waits.

You'll see at most one "Always Allow" prompt, the first time Claudius reads the item. If you deny it, Claudius backs off and won't ask again until you click **Sync Now** or relaunch. When the token expires, Claudius simply waits for Claude Code to refresh it and uses another source in the meantime.

macOS ties the one-time "Always Allow" grant to the app's designated requirement (its code signature). For that grant to persist across updates, release builds must be signed with a stable Developer ID — a fixed Team ID and bundle identifier — so the designated requirement doesn't change from one build to the next. Unsigned or ad-hoc builds get a new identity each time and will re-prompt.

## Features

- **Zero-config** — reads the Claude desktop app's usage cache, or the CLI's Keychain token; no session keys or org IDs to copy
- **Customizable menu bar** — show every reported usage window as bars, numbers, both, or a single session percentage
- **Model-scoped caps** — surfaces a per-model weekly limit (e.g. Fable) automatically when your account reports one
- **Dashboard window** — one progress bar and reset countdown per usage window
- **Layered fallback** — desktop cache, then the OAuth API, then local JSONL estimates
- **Plan presets** — select Claude Pro, Max 5x, or Max 20x to set your limits
- **Tidbyt integration** — push a live usage display to your Tidbyt LED device (optional)
- **Background sync** — refreshes every 5 minutes

## Requirements

- **macOS 15+** (Sequoia)
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** installed and signed in — via the Claude desktop app, or by running `claude` in your terminal
- **Tidbyt device + [Pixlet CLI](https://github.com/tidbyt/pixlet)** — only needed for the Tidbyt display

## Installation

### Download

Grab the `.dmg` from the [Releases](https://github.com/nsluke/Claudius/releases) page, open it, and drag Claudius to your Applications folder.

> Releases are signed with a Developer ID and notarized by Apple, so the app opens normally on first launch.

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

1. Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and sign in to your claude.ai account
2. Launch Claudius — it finds a usage source automatically
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
├── DesktopUsageReader.swift     # Reads the Claude desktop app's usage cache (preferred source)
├── ClaudeWebUsageService.swift  # Anthropic OAuth API transport + diagnostics
├── UsageBucket.swift            # Usage-window model and tolerant response decoding
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
