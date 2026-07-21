# tmux-agent-resumer

Detect Claude Code agents in tmux panes that died mid-turn on an API limit
(HTTP 429), and resume them via poll-and-retry with backoff. Sibling to
[tmux-agent-tracker](../tmux-agent-tracker).

## Status: scaffold (resume path held behind a reproduction gate)

Two limit types, handled differently (see the plan doc for the full investigation):

| | Spend cap | Usage rate limit (5h / weekly) |
|---|---|---|
| Message | "monthly spend limit" | "session/weekly/Opus/Sonnet/Fable 5 limit" |
| Cleared by waiting? | No (admin `/usage-credits` or billing cycle) | Yes |
| Reset time on disk? | Never | Only a lossy display string, sometimes |
| Behavior | long-capped backoff + notify | exponential backoff, resumes after reset |

The reset epoch (`anthropic-ratelimit-unified-reset`) is never persisted locally,
so this tool does **not** schedule to an exact reset instant. Poll-and-retry with
backoff needs no reset epoch.

### What ships now (safe, no pane side effects)
- `resumer.sh detect-file <transcript.jsonl>` - pure analyzer; prints `NONE` or `<type>\t<message>`.
- `resumer.sh hook <event>` - **observational**: logs whether the hook fired and
  whether a 429 was seen. Writes no state, types nothing.
- `init` / `status-bar` / `refresh` / `cleanup` plumbing + `limited` table schema.

### Held until the reproduction gate passes
- The `limited` state machine (insert / backoff / reschedule).
- `cmd_retry`'s `tmux send-keys` resume (guarded by `@agent-resumer-enabled`, default `off`).

**Reproduction gate** (do this before enabling resume):
1. `./install.sh` (registers `Stop` + `StopFailure` hooks in `~/.claude/settings.json`; makes a backup).
2. Next time an agent hits a limit, check `~/.tmux-agent-resumer/debug.log` for a
   `DETECTED 429` line. That proves the hook fires. Note the pane state (idle prompt? empty input box?).
3. Only then wire the resume path and `tmux set -g @agent-resumer-enabled on`.

## Test
```
bats tests/resumer.bats
```

## Config (tmux options)
`@agent-resumer-enabled` (off), `@agent-resumer-usage-backoff-floor` (120),
`@agent-resumer-spend-backoff-floor` (1800), `@agent-resumer-backoff-cap` (3600),
`@agent-resumer-usage-retry-cap` (12), `@agent-resumer-spend-retry-cap` (48),
`@agent-resumer-resume-prompt` (continue), `@agent-resumer-debug-log` (1).

## Known unknowns (honest)
- Whether `Stop`/`StopFailure` fires on a 429 is unconfirmed - the whole trigger depends on it.
  If it does not, fall back to a periodic transcript-tail poller.
- Whether `send-keys "continue"` reliably resumes is unconfirmed.
- Spend-cap retries are mostly futile within a billing month; the honest behavior there is
  long-backoff + notify, not fast retry.
- JSON matcher spacing assumptions need validation against a real transcript.
