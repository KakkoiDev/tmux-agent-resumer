# tmux-agent-resumer

Monitor Claude Code usage from tmux, warn before you spill into paid overage, and
auto-resume agents that stalled on a rate limit once their window resets. Sibling to
[tmux-agent-tracker](../tmux-agent-tracker). Pure bash + SQLite, hook-driven, no daemon.

## Features

### `<prefix>+R` modal - usage + paused agents
Shows your live limits and every agent currently waiting on a limit:
```
Session  33%   resets Tue 18:29 (3h)
Weekly   19%   resets Sun 03:59 (4d)
  Fable weekly: 3%
Credits  15%   (7.65/50.00 USD)
---
! project-x [usage]     <- select to jump to that pane
Refresh (r)   Quit (q)
```
Usage comes from `GET /api/oauth/usage` (OAuth token from the macOS keychain,
`Claude Code-credentials`), cached to `~/.claude.json` as fallback. Selecting a paused
agent runs `switch-client`/`select-window`/`select-pane` to it.

### Spill alert (#2)
The status bar shows a red `SPILL S91 C82` when the session/weekly/credits utilization
crosses its threshold - i.e. the next tokens would spill from your included plan into
**paid** overage. Purely informational; lets you choose pause vs pay.

### Auto-resume (#3) - opt-in, default OFF
When an agent's turn dies on a 429, resumer types the resume prompt (default `resume`)
into that pane to re-issue the request. This does **not** bypass anything: the API still
enforces the limit server-side; a retry while still limited just 429s again and backs off.
For usage/rate limits the first retry is scheduled at the real reset time (from the usage
endpoint); the spend cap uses a long bounded backoff. Guards: won't type while you're at the
keyboard on that pane, but if the client has been idle past `@agent-resumer-idle-grace`
(you walked away without switching panes) it resumes anyway; gives up if the pane/agent is
gone or the retry cap is hit.

While any agent is paused, resumer holds a `caffeinate -i` so the Mac doesn't idle-sleep
and freeze the resume timer (Claude Code's own caffeinate lapses once the agent stalls). It
releases when nothing is paused. Idle-sleep only - closing the lid still sleeps. Disable with
`@agent-resumer-caffeinate off`.

Enable it only after confirming it works for you (see gate below):
```
tmux set -g @agent-resumer-enabled on
```

## Install
```
./install.sh          # registers Stop+StopFailure hooks (symlink-safe), binds <prefix>+R
```
Persist across tmux restarts - add to `~/.tmux.conf`:
```
run-shell /path/to/tmux-agent-resumer/agent-resumer.tmux
```

## Verification gate (before enabling auto-resume)
1. Install. Open `<prefix>+R` - confirm your usage shows.
2. On the next real limit hit, check `~/.tmux-agent-resumer/debug.log` for a `DETECTED 429`
   line (proves the Stop/StopFailure hook fires) and note the pane state.
3. Confirm `resume`+Enter is what the post-429 TUI needs to continue (adjust
   `@agent-resumer-resume-prompt` if not). Then set `@agent-resumer-enabled on`.

## Test
```
bats tests/resumer.bats
```

## Config (tmux options)
`@agent-resumer-enabled` (off), `@agent-resumer-key` (R),
`@agent-resumer-resume-prompt` (resume),
`@agent-resumer-warn-session` (90), `@agent-resumer-warn-weekly` (90),
`@agent-resumer-warn-credits` (80), `@agent-resumer-idle-grace` (60),
`@agent-resumer-caffeinate` (on),
`@agent-resumer-usage-backoff-floor` (120), `@agent-resumer-spend-backoff-floor` (1800),
`@agent-resumer-backoff-cap` (3600), `@agent-resumer-usage-retry-cap` (12),
`@agent-resumer-spend-retry-cap` (48), `@agent-resumer-debug-log` (1).

## Honest unknowns
- Whether `Stop`/`StopFailure` fires on a 429 is unconfirmed - the hook-driven trigger
  depends on it. A hook-independent periodic scan (`cmd_scan` via `refresh`) is the fallback.
- Whether `resume`+Enter is the exact keystroke the post-429 TUI needs is unconfirmed.
- The send-keys mechanism itself is verified (keystrokes reach the target pane).
- Spend-cap retries are mostly futile within a billing month; expect give-up + a badge there.
