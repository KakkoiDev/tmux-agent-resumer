# TASK: guard the resume injection on composer content

Created: 2026-07-28
For: another agent. Read this whole file first, then `scripts/resumer.sh`.
Source of the finding: comparing this repo's injection against
`kunchenguid/firstmate` (`bin/fm-composer-lib.sh`, `bin/fm-tmux-lib.sh`, MIT).

## Verdict first: this repo is not behind. It has two guards firstmate lacks.

Do not rewrite the injection path. It is stronger than firstmate's on two axes
and the port below is narrow.

**Guard 1, process-level agent liveness** (`scripts/resumer.sh:407`):

```bash
if [[ -n "$ppid" ]] && ! _has_agent_child "$ppid"; then
    sql "UPDATE limited SET status='gaveup' ..."
```

Firstmate infers "this pane is a dead shell" from a bare `$`/`>`/`%`/`#` glyph on
an unstructured row. This repo reads the process table instead. That is the better
answer to the same question and it must not be lost in the port.

**Guard 2, do not type while the human is at the keyboard**
(`scripts/resumer.sh:412-431`): the `pane_active && window_active &&
session_attached` probe, with the `IDLE_GRACE` escape so it does not defer
forever. Firstmate has no equivalent.

## The actual gap: both injection paths are blind to composer content

There are two sites and they fail differently.

**Site A, the 429 retry path (`scripts/resumer.sh:468-469`):**

```bash
_type_prompt "$pane" "$rp"
tmux send-keys -t "$pane" Enter 2>/dev/null || true
```

No clear, no content check. If the operator left a half-typed line in the
composer, `resume` is appended to it and `Enter` submits the concatenation. The
agent receives `my half typed thoughtresume` as its prompt.

**Site B, the credit-guard resume path (`scripts/resumer.sh:437-441`):**

```bash
_prep_input "$pane"
tmux send-keys -t "$pane" C-u 2>/dev/null || true       # clear the typed notice
_type_prompt "$pane" "$rp" 1
tmux send-keys -t "$pane" Enter 2>/dev/null || true
```

The `C-u` is defensible in intent: it clears the `CREDIT_NOTICE` this repo typed
itself at `:542`. But `C-u` is content-blind, so anything the operator typed after
that notice is destroyed with it.

The active-pane guard bounds both, but only while a client is attached and was
active within `IDLE_GRACE` (default 60s). Past that it proceeds regardless, which
is the documented and correct trade for auto-resume. So the exposure is real:
walk away mid-sentence, come back to a mangled or vanished line.

**Severity is low, and stating why matters.** The injected text is
`RESUME_PROMPT` (default `resume`) or the per-session `resume_prompt` column, both
operator-controlled. It is never third-party content. This is not a command
execution issue; it is input corruption. Do not escalate it in the report.

## The port: firstmate's composer classifier, as a gate only

Add a content check before each injection. Defer, do not clear.

Technique from `fm-composer-lib.sh`, all four parts required:

1. **Capture with styling.** `tmux capture-pane -e` rather than `-p` alone. Every
   existing capture in this repo (`:253`, `:283`, `:1009-1016`) drops ANSI, which
   is why content classification is not possible today.
2. **Strip ghost text by style, not by pattern.** Harnesses fill an empty composer
   with de-emphasised placeholder text that a plain capture cannot tell from typed
   input:
   - dim runs (SGR 2): Claude Code and Codex suggestion text. Ended by SGR 0 or 22.
   - dark truecolor foregrounds (`38;2;r;g;b` and the colon form `38:2::r:g:b`)
     whose luminance `0.299R + 0.587G + 0.114B` is under a threshold: Grok
     placeholders. Ended by SGR 0, 39, any 30-37/90-97, or a lighter 38;2.
   - leave 256-colour (`38;5;n`) alone: palette-dependent, and under-stripping only
     defers while over-stripping would type over real input.
   Without this the classifier reads the harness's own rotating "Type a message..."
   as operator input and defers forever. Firstmate's source names that as the
   overnight wedge that forced the consolidation.
3. **Three-way verdict**, `empty | pending | unknown`. Inject only on `empty`.
   Both other states defer via the existing `_schedule_retry "$sid" "$backoff"`.
4. **Keep the dead-shell rule even though guard 1 covers it.** `❯` (Claude) and `›`
   (Codex) are genuine empty agent composers, bordered or bare. `>` `$` `%` `#`
   count as empty **only inside a bordered composer box**. Belt and braces: guard 1
   is process-level, this is screen-level, and they fail independently.

Then at each site:

- Site A: classify; on `empty` proceed unchanged; otherwise defer with a debug
  line naming the verdict.
- Site B: classify; on `empty` proceed **without the `C-u`**, since an empty
  composer has nothing to clear. On `pending`, defer rather than clearing. The
  notice-accumulation problem the `C-u` was solving needs the notice tracked, not
  the composer wiped.

Optional, from `fm_tmux_submit_enter_core`: after `Enter`, re-classify and retry.
Still `pending` on a busy pane means the harness queued it, so treat as submitted.
Still `pending` on an idle pane is a genuine swallow. This is the only
acknowledgement available for a keystroke path and it costs one extra capture.

## Constraints

- **bash 3.2.** This repo's suite runs under macOS system bash. No `declare -A`,
  no `mapfile`, no `${var,,}`. Firstmate's strip is `awk`, which is portable; keep
  it as `awk` rather than translating to bash string ops.
- **One owner for the decision.** Firstmate's file header records why it exists:
  four backend adapters each carried a copy of this classification and the copies
  drifted, and the dangerous drift was the dead-shell case. Put the classifier in
  `scripts/helpers.sh` and have both sites call it. Do not inline it twice.
- **Attribution.** Firstmate is MIT, same as this repo. Credit
  `kunchenguid/firstmate` in the function's comment. Do not copy the file verbatim
  without the notice.
- **Do not import firstmate's backend abstraction.** This repo is tmux-only and
  should stay that way.

## Tests required

The suite is `tests/resumer.bats`. Each of these must fail if the guard is
reverted:

1. A composer holding typed text yields `pending`, and the retry path defers
   instead of typing. Assert no `send-keys` reached the pane.
2. A composer holding only dim ghost text yields `empty`. Build the fixture from
   **real captured bytes** with `capture-pane -e` against a live agent, committed
   as a fixture file. A hand-written escape sequence will not catch what the
   harness actually emits.
3. A bare `$` on an unstructured row yields `unknown`, not `empty`.
4. A `❯` on a bare row yields `empty`.
5. Site B does not send `C-u` when the verdict is `empty`.
6. A truecolor foreground above the luminance threshold is kept, not stripped.

Note in the test comments that the luminance branch **assumes a dark terminal
theme**, which firstmate states explicitly in its source. The SGR-2 branch is
theme-independent. If the fixture is captured on a light theme the threshold will
be wrong.

## Out of scope

- Do not change the backoff, the retry caps, the credit-guard ETA pinning, or the
  usage endpoint. This task is the content gate and nothing else.
- Do not touch `_interrupt_pane`. The spaced-Escape logic is load-bearing (a rapid
  double-Escape opens Claude's rewind menu) and is unrelated.

## Why this matters beyond this repo

`tmux-agent-mesh` is about to grow a wake path that types into panes, and its
payload is **another agent's message text**, not an operator-configured string.
There the same blindness is a command execution hole rather than input corruption.
The classifier should land here first, where the stakes are low and the guards are
already good, then be lifted into mesh with all three gates combined:
process liveness (this repo), not-under-the-operator's-eyes (this repo), and
composer `empty` (firstmate).
