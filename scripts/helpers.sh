#!/usr/bin/env bash
# helpers.sh - a shim over the vendored tmux-toolkit.
#
# This file was lifted wholesale from tmux-agent-tracker/scripts/helpers.sh, so
# _file_mtime, get_tmux_option and check_tmux_version here were byte-identical to
# the tracker's and to mesh's, and load_config was the same cache architecture
# written a fourth time. They now delegate to lib/, so a fix lands once.
#
# The old names are kept: resumer.sh and agent-resumer.tmux call them at ~90
# sites, and renaming those is a separate change from extracting them. Every
# signature and return value is unchanged.

if [[ -z "${AGENT_RESUMER_PLUGIN_DIR:-}" ]]; then
    AGENT_RESUMER_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck disable=SC2034  # used by callers that source this file
SCRIPTS_DIR="$AGENT_RESUMER_PLUGIN_DIR/scripts"

# shellcheck source=../lib/toolkit.sh
source "$AGENT_RESUMER_PLUGIN_DIR/lib/toolkit.sh"
tk_require_version 0.2.0

# tk_init is deferred to load_config: resumer.sh sources this file before it
# resolves RESUMER_DIR, so the data dir is not knowable yet at source time.
_resumer_tk_init() { tk_init agent-resumer "${RESUMER_DIR:-$HOME/.tmux-agent-resumer}"; }

# ── platform helpers ──────────────────────────────────────────────────

_file_mtime() { tk_mtime "$1"; }

# Does shell $1 still have a live agent child? Same detection the tracker
# uses; a resume target is pointless if the agent process is gone.
# Every process name that counts as an agent harness. One list, so adding a
# harness is one edit rather than one per platform branch.
#
# Keep this list identical to tmux-agent-tracker/scripts/helpers.sh. It drifted
# once already: the tracker listed eight names and this file's Linux branch
# listed five, dropping deer, deerbox and agy, so on Linux an agent the
# tracker's reaper could see was invisible to this give-up check and a live
# session was marked gaveup. Both are destined for the shared lib/identity.sh.
_AGENT_COMMS="claude codex gemini deer deerbox pi agy antigravity"

# _has_agent_child <pane_pid> - is an agent harness this pid, or a direct child?
#
# One `ps | awk` for both platforms, not a Darwin/Linux fork.
#
# `comm`, never `pane_current_command`: Claude Code rewrites argv[0] to its own
# version string, so tmux reports the pane's command as e.g. "2.1.220".
#
# Two things the ppid-only, exact-match version got wrong. Both measured here:
#
#   * It matched `$1 == p` where $1 is ppid, so it could only ever find a CHILD.
#     A pane whose OWN process is the harness has no agent child, and that is
#     exactly the shape `tmux-agent-mesh dispatch` creates - its own test is
#     "dispatch runs the harness as the pane's own process". Every dispatched
#     agent was therefore invisible: the tracker's _reap_dead deleted its row
#     with reason=no_agent, and the resumer marked it "gaveup: no live agent".
#   * `ps -eo comm` prints the executable *as invoked*, not its basename. A bare
#     PATH invocation gives `claude`, but an absolute one gives
#     `/opt/homebrew/bin/claude`, which never equalled "claude". The old comment
#     asserted a bare name was verified on this platform; that only held for the
#     PATH case.
#
# The command is taken as the rest of the line rather than as field 3, because a
# comm can contain spaces: this machine has
# `/Applications/Claude.app/.../Claude Helper (Renderer)` running right now.
#
# Named _has_agent_child rather than _pane_has_agent because ~20 test bodies stub
# it by that name; renaming it in production without them would leave those stubs
# silently inert. Rename when it moves into lib/identity.sh, stubs and all.
_has_agent_child() {
    local pid="$1"
    [[ -n "$pid" ]] || return 1
    ps -eo pid,ppid,comm 2>/dev/null | awk -v p="$pid" -v names="$_AGENT_COMMS" '
        BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
        NR == 1 { next }
        {
            cmd = $0
            sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "", cmd)
            sub(/.*\//, "", cmd)
            if (($1 == p || $2 == p) && (cmd in want)) { found = 1; exit }
        }
        END { exit !found }
    '
}

# ── tmux option helpers ──────────────────────────────────────────────

get_tmux_option() { tk_opt "$1" "${2:-}"; }

# ── config ────────────────────────────────────────────────────────────

# Declared so resumer.sh and agent-resumer.tmux can read them under `set -u`
# before load_config has run. One `declare` rather than 25 assignments, so a
# single SC2034 directive covers all of them: the writes are invisible to the
# linter because tk_config_load assigns through tk_opt_into, which has to be an
# eval since bash 3.2 has no namerefs.
# shellcheck disable=SC2034
declare ENABLED="" COLOR="" ICON_WAITING="" ICON_GAVEUP="" \
        USAGE_BACKOFF_FLOOR="" SPEND_BACKOFF_FLOOR="" BACKOFF_CAP="" \
        USAGE_RETRY_CAP="" SPEND_RETRY_CAP="" RESUME_PROMPT="" \
        WARN_SESSION="" WARN_WEEKLY="" WARN_CREDITS="" IDLE_GRACE="" \
        CAFFEINATE="" NTFY_TOPIC="" ALLOW_CREDITS="" CREDIT_THRESHOLD="" \
        INTERRUPT_ESCAPES="" CREDIT_NOTICE="" RESUME_JITTER="" \
        INTERRUPT_PAUSE="" GUARD_COOLDOWN="" VIM_MODE="" DEBUG_LOG=""

# A spec is VARNAME:@option:default. The comments that used to sit above each
# get_tmux_option call are kept, because they document policy rather than syntax.
_RESUMER_CONFIG_SPECS=(
    # Master kill switch. Default OFF: nothing types into a pane until the user
    # opts in after the reproduction gate is satisfied.
    'ENABLED:@agent-resumer-enabled:off'
    'COLOR:@agent-resumer-color:yellow'
    'ICON_WAITING:@agent-resumer-icon-waiting:~'
    'ICON_GAVEUP:@agent-resumer-icon-gaveup:x'
    'USAGE_BACKOFF_FLOOR:@agent-resumer-usage-backoff-floor:120'
    'SPEND_BACKOFF_FLOOR:@agent-resumer-spend-backoff-floor:1800'
    'BACKOFF_CAP:@agent-resumer-backoff-cap:3600'
    'USAGE_RETRY_CAP:@agent-resumer-usage-retry-cap:12'
    'SPEND_RETRY_CAP:@agent-resumer-spend-retry-cap:48'
    'RESUME_PROMPT:@agent-resumer-resume-prompt:resume'
    # Spill-alert thresholds (percent). Crossing = next tokens hit paid overage.
    'WARN_SESSION:@agent-resumer-warn-session:90'
    'WARN_WEEKLY:@agent-resumer-warn-weekly:90'
    'WARN_CREDITS:@agent-resumer-warn-credits:80'
    # Resume a focused pane anyway if its client has been idle this long (walked away).
    'IDLE_GRACE:@agent-resumer-idle-grace:60'
    # Hold a caffeinate (block idle sleep) while any agent is paused, so the resume
    # timer survives lunch. Does not beat closing the lid.
    'CAFFEINATE:@agent-resumer-caffeinate:on'
    # ntfy.sh topic for phone push on limit-hit / resume / give-up. Empty = off.
    'NTFY_TOPIC:@agent-resumer-ntfy-topic:'
    # Credit safety: off (default) = block paid usage-credit spend. When the session
    # window crosses CREDIT_THRESHOLD%, interrupt agents so they don't spend, wait for
    # reset, resume. on = allow credits (emergency company extra usage).
    'ALLOW_CREDITS:@agent-resumer-allow-credits:off'
    'CREDIT_THRESHOLD:@agent-resumer-credit-threshold:100'
    # How many Escapes to send to interrupt a turn (1 = plain interrupt; >1 risks
    # opening Claude's rewind menu - verify on a live pane before raising).
    'INTERRUPT_ESCAPES:@agent-resumer-interrupt-escapes:3'
    # Notice typed into the paused pane's input box (not submitted).
    'CREDIT_NOTICE:@agent-resumer-credit-notice:[Credit usage disabled - enable in resumer options]'
    # Seconds of random jitter added to each scheduled retry so a global reset does
    # not release every paused agent simultaneously.
    'RESUME_JITTER:@agent-resumer-resume-jitter:30'
    # Seconds to wait after an interrupt Escape before typing, so the Escape lands
    # as a standalone interrupt instead of merging with the next key into a sequence.
    'INTERRUPT_PAUSE:@agent-resumer-interrupt-pause:1'
    # Min seconds between credit-guard actions on the same session - stops the notice
    # being re-typed every scan while an agent stays busy; still re-blocks after this.
    'GUARD_COOLDOWN:@agent-resumer-guard-cooldown:90'
    # Claude Code vim-mode input: auto (detect from pane), on, or off. In vim mode
    # text must be typed in insert state or it is eaten as normal-mode commands.
    'VIM_MODE:@agent-resumer-vim-mode:auto'
    'DEBUG_LOG:@agent-resumer-debug-log:1'
)

load_config() {
    _resumer_tk_init
    tk_config_load agent-resumer 60 "${_RESUMER_CONFIG_SPECS[@]}"
}

# ── version check ────────────────────────────────────────────────────

check_tmux_version() { tk_vers_ge "${1:-3.0}"; }

ensure_tmux_version() { tk_vers_require 3.0 tmux-agent-resumer; }
