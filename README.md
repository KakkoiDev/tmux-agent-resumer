# tmux-agent-resumer

> `lib/` is vendored from [tmux-toolkit](https://github.com/KakkoiDev/tmux-toolkit)
> via `git subtree`; do not edit it in place, CI fails on drift. If you are an agent
> picking up in-flight work on this plugin, start at
> [tmux-toolkit `docs/RESUME.md`](https://github.com/KakkoiDev/tmux-toolkit/blob/main/docs/RESUME.md).

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

## Verify it works
- `tmux-agent-resumer doctor` - checks deps, keychain/token, usage endpoint, DB,
  hooks, status segment, and prints current config. Run this first.
- `tmux-agent-resumer selftest <pane>` - sends `Escape` then types the resume prompt
  into a REAL (non-limited) Claude pane and shows before/after captures, so you can
  confirm the interrupt/resume keystrokes actually drive the TUI. Non-destructive
  (clears the input; add `--submit` to actually send). Find the pane with
  `tmux list-panes -a`. Do NOT target the pane you're typing in.

Then, before enabling auto-resume: on the next real limit hit, check
`~/.tmux-agent-resumer/debug.log` for `DETECTED 429`, then `tmux set -g @agent-resumer-enabled on`.

## Test / CI
```
bats tests/resumer.bats
shellcheck -S warning scripts/*.sh
```
GitHub Actions runs both on every push (`.github/workflows/ci.yml`).

## Commands
`doctor`, `selftest <pane> [--submit]`, `menu` (<prefix>+R), `usage`, `refresh`,
`sweep`, `scan`, `cleanup`, `toggle <enabled|caffeinate|allow-credits>`, `options`.

## Config (tmux options)
`@agent-resumer-enabled` (off), `@agent-resumer-allow-credits` (off),
`@agent-resumer-key` (R), `@agent-resumer-resume-prompt` (resume),
`@agent-resumer-warn-session` (90), `@agent-resumer-warn-weekly` (90),
`@agent-resumer-warn-credits` (80), `@agent-resumer-idle-grace` (60),
`@agent-resumer-caffeinate` (on), `@agent-resumer-ntfy-topic` (""),
`@agent-resumer-credit-threshold` (100), `@agent-resumer-interrupt-escapes` (1),
`@agent-resumer-credit-notice` (...), `@agent-resumer-resume-jitter` (30),
`@agent-resumer-usage-backoff-floor` (120), `@agent-resumer-spend-backoff-floor` (1800),
`@agent-resumer-backoff-cap` (3600), `@agent-resumer-usage-retry-cap` (12),
`@agent-resumer-spend-retry-cap` (48), `@agent-resumer-debug-log` (1).

## Honest unknowns
- Whether `Stop`/`StopFailure` fires on a 429 is unconfirmed - the hook-driven trigger
  depends on it. A hook-independent periodic scan (`cmd_sweep`/`cmd_scan` via `refresh`,
  which also self-heals after a tmux restart) is the fallback.
- Whether `resume`+Enter and `Escape` are the exact keystrokes the post-429 TUI needs is
  unconfirmed against a live limit - run `selftest` to check. The send-keys mechanism
  itself is verified (keystrokes reach the target pane).
- The credit-guard interrupt cannot truly PREVENT spend (detection lags the switch);
  it minimizes it. It also interrupts in-flight turns - real blast radius.
- Spend-cap retries are mostly futile within a billing month; expect give-up + a badge there.
