# claude-statusline

A car-dashboard style statusline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) that gives you real-time visibility into everything that matters during a session.

![macOS](https://img.shields.io/badge/platform-macOS-lightgrey)
![bash](https://img.shields.io/badge/shell-bash-green)
![jq](https://img.shields.io/badge/requires-jq-blue)

## What it looks like

```
rate     [195k/h ▶▶▶▶···········][$1.82/h $$··················]
think    [●●●●●●●●●●●●●●●●●●··························]
context  [   ◇805k    ][  ◆148k  ][ ▼30k ][ ▲16k ]
5h ·●┃·· [          72%          ┃                            ]
7d ··┃●· [    38%    ┃                                        ]
tokens   [  ses 214k  ][     day 580k     ][     all 1.2m     ]
cost     [ ses $2 ][    day $6    ][         all $48          ]
✦ Claude Opus 4.6 │ ◉ my-project │ ⎇ main ✓
```

## Features

### API throughput + cost rate
The **rate** bar is a split gauge showing two things at once:
- **Left half** — token throughput in tokens/hour (`▶` fill), scaled 0-1M. See at a glance whether the API is humming or crawling.
- **Right half** — burn rate in $/hour (`$` fill). Green under $5/h, yellow $5-10/h, red above $10/h.

### Think time ratio
The **think** bar shows what percentage of your wall-clock session time Claude is actually spending on API calls vs. waiting for you. A full bar means Claude is doing all the work. A mostly-empty bar means you're the bottleneck (or taking a well-deserved break).

### Context window breakdown
The **context** bar splits your context window into four color-coded segments:
- **◇ free** (green/yellow/red) — remaining capacity. Color shifts as you approach the limit: green < 65%, yellow 65-80%, red > 80%.
- **◆ cache** (bright red) — cached input tokens being reused.
- **▼ input** (medium red) — fresh input tokens this turn.
- **▲ output** (dim red) — output tokens.

Each segment is labeled with a human-readable token count (e.g., `◇805k`, `◆148k`).

### Rate limit timelines (5-hour + 7-day)
Two timeline bars track your Anthropic API rate limits with a fuel-gauge metaphor:

- A **speed gauge** (`·●┃··`) on the left shows your projected burn rate — green means you're well within limits, yellow means you're on pace to hit the cap, red means you'll run dry before the window resets.
- The **timeline bar** shows three zones:
  - **Fuel** (colored) — how much capacity remains, labeled with a percentage.
  - **Wait** (dark red) — projected time you'd be rate-limited if you keep going at this pace. Shows a countdown like `◷2h30m`.
  - **Elapsed** (grey) — time already passed in the current window.
- A **┃ marker** shows where "now" sits in the window.

The burn rate multiplier is calculated by projecting current usage over the full window (5h or 7d). Under 0.9x = green (plenty of headroom), 0.9-1.1x = yellow (on pace), over 1.1x = red (will hit the limit).

### Token tracking (session / day / all-time)
The **tokens** bar is a stacked bar showing cumulative token usage across three scopes:
- **ses** (bright blue) — tokens used in the current session.
- **day** (medium blue) — total tokens used today across all sessions.
- **all** (dim blue) — all-time token usage.

The segments scale proportionally so you can see at a glance how today compares to your total history.

### Cost tracking (session / day / all-time)
The **cost** bar works the same way in gold tones:
- **ses** (bright gold) — current session cost.
- **day** (medium gold) — today's total cost.
- **all** (dim gold) — all-time cost.

Costs are persisted to `~/.claude/usage_costs.tsv` so all-time tracking survives across sessions.

### Identity line
The bottom line shows:
- **Model** (orange) — which Claude model is active (e.g., `Opus 4.6`).
- **Directory** (cyan) — current working directory.
- **Git branch** (purple) — current branch with status indicators:
  - `✓` green check = clean working tree
  - `+N` green = N staged files
  - `~N` yellow = N modified/untracked files

## Requirements

- **macOS** (uses `security` for keychain access, `date -j` for time parsing)
- **jq** — `brew install jq`
- **Claude Code** with a Pro/Team/Enterprise subscription (for the rate limit API)

## Install

```bash
git clone https://github.com/tonfield/claude-statusline.git
cd claude-statusline
bash install.sh
```

The installer:
- Copies the scripts to `~/.claude/`
- Merges the `statusLine` config and usage-fetching hooks into your existing `settings.json` without overwriting your other settings

Restart Claude Code after installing.

## Uninstall

```bash
cd claude-statusline
bash uninstall.sh
```

Cleanly removes the scripts, settings entries, and cached data.

## How it works

The statusline is a bash script (`statusline-command.sh`) that Claude Code calls on every render. It receives session state as JSON on stdin and outputs ANSI-colored text.

Rate limit data comes from the Anthropic usage API, fetched in the background by `fetch-usage.sh`. This runs automatically via Claude Code hooks (on every tool use and when Claude stops) and caches results for 60 seconds to avoid hammering the API.

Cost and token history is tracked in a simple TSV file (`~/.claude/usage_costs.tsv`), one row per session, updated on every statusline render.
