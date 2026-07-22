#!/usr/bin/env bash
# helpers.sh - Config loading and tmux/process helpers for tmux-agent-resumer.
# Lifted from tmux-agent-tracker/scripts/helpers.sh; option namespace is
# @agent-resumer-* so it coexists with the tracker.

if [[ -z "${AGENT_RESUMER_PLUGIN_DIR:-}" ]]; then
    AGENT_RESUMER_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
# shellcheck disable=SC2034  # used by callers that source this file
SCRIPTS_DIR="$AGENT_RESUMER_PLUGIN_DIR/scripts"

# ── platform helpers ──────────────────────────────────────────────────

_file_mtime() {
    case "$(uname)" in
        Darwin) stat -f %m "$1" ;;
        *)      stat -c %Y "$1" ;;
    esac
}

# Does shell $1 still have a live agent child? Same detection the tracker
# uses; a resume target is pointless if the agent process is gone.
_has_agent_child() {
    local shell_pid="$1"
    case "$(uname)" in
        Darwin)
            ps -eo ppid,comm | awk -v p="$shell_pid" '$1 == p && ($2 == "claude" || $2 == "codex" || $2 == "gemini" || $2 == "deer" || $2 == "deerbox" || $2 == "pi" || $2 == "agy" || $2 == "antigravity")' | grep -q . ;;
        *)
            pgrep -P "$shell_pid" -x "claude" >/dev/null 2>/dev/null || \
            pgrep -P "$shell_pid" -x "codex" >/dev/null 2>/dev/null || \
            pgrep -P "$shell_pid" -x "gemini" >/dev/null 2>/dev/null || \
            pgrep -P "$shell_pid" -x "pi" >/dev/null 2>/dev/null || \
            pgrep -P "$shell_pid" -x "antigravity" >/dev/null 2>/dev/null ;;
    esac
}

# ── tmux option helpers ──────────────────────────────────────────────

get_tmux_option() {
    local option="$1" default="${2:-}"
    local value
    value=$(tmux show-option -gqv "$option" 2>/dev/null) || true
    printf '%s' "${value:-$default}"
}

# ── config ────────────────────────────────────────────────────────────

ENABLED=""
COLOR=""
ICON_WAITING=""
ICON_GAVEUP=""
USAGE_BACKOFF_FLOOR=""
SPEND_BACKOFF_FLOOR=""
BACKOFF_CAP=""
USAGE_RETRY_CAP=""
SPEND_RETRY_CAP=""
RESUME_PROMPT=""
WARN_SESSION=""
WARN_WEEKLY=""
WARN_CREDITS=""
IDLE_GRACE=""
CAFFEINATE=""
NTFY_TOPIC=""
ALLOW_CREDITS=""
CREDIT_THRESHOLD=""
INTERRUPT_ESCAPES=""
CREDIT_NOTICE=""
RESUME_JITTER=""
VIM_MODE=""
DEBUG_LOG=""

load_config() {
    local cache="${RESUMER_DIR:-$HOME/.tmux-agent-resumer}/config_cache"
    if [[ -f "$cache" ]]; then
        local age now
        now=$(date +%s)
        age=$(( now - $(_file_mtime "$cache" 2>/dev/null || echo 0) ))
        if [[ "$age" -lt 60 ]]; then
            # shellcheck disable=SC1090  # runtime-generated cache path
            source "$cache"
            return
        fi
    fi

    # Master kill switch. Default OFF: nothing types into a pane until the
    # user opts in after the reproduction gate is satisfied.
    ENABLED=$(get_tmux_option "@agent-resumer-enabled" "off")
    COLOR=$(get_tmux_option "@agent-resumer-color" "yellow")
    ICON_WAITING=$(get_tmux_option "@agent-resumer-icon-waiting" "~")
    ICON_GAVEUP=$(get_tmux_option "@agent-resumer-icon-gaveup" "x")
    USAGE_BACKOFF_FLOOR=$(get_tmux_option "@agent-resumer-usage-backoff-floor" "120")
    SPEND_BACKOFF_FLOOR=$(get_tmux_option "@agent-resumer-spend-backoff-floor" "1800")
    BACKOFF_CAP=$(get_tmux_option "@agent-resumer-backoff-cap" "3600")
    USAGE_RETRY_CAP=$(get_tmux_option "@agent-resumer-usage-retry-cap" "12")
    SPEND_RETRY_CAP=$(get_tmux_option "@agent-resumer-spend-retry-cap" "48")
    RESUME_PROMPT=$(get_tmux_option "@agent-resumer-resume-prompt" "resume")
    # Spill-alert thresholds (percent). Crossing = next tokens hit paid overage.
    WARN_SESSION=$(get_tmux_option "@agent-resumer-warn-session" "90")
    WARN_WEEKLY=$(get_tmux_option "@agent-resumer-warn-weekly" "90")
    WARN_CREDITS=$(get_tmux_option "@agent-resumer-warn-credits" "80")
    # Resume a focused pane anyway if its client has been idle this long (walked away).
    IDLE_GRACE=$(get_tmux_option "@agent-resumer-idle-grace" "60")
    # Hold a caffeinate (block idle sleep) while any agent is paused, so the resume
    # timer survives lunch. Does not beat closing the lid.
    CAFFEINATE=$(get_tmux_option "@agent-resumer-caffeinate" "on")
    # ntfy.sh topic for phone push on limit-hit / resume / give-up. Empty = off.
    NTFY_TOPIC=$(get_tmux_option "@agent-resumer-ntfy-topic" "")
    # Credit safety: off (default) = block paid usage-credit spend. When the session
    # window crosses CREDIT_THRESHOLD%, interrupt agents so they don't spend, wait for
    # reset, resume. on = allow credits (emergency company extra usage).
    ALLOW_CREDITS=$(get_tmux_option "@agent-resumer-allow-credits" "off")
    CREDIT_THRESHOLD=$(get_tmux_option "@agent-resumer-credit-threshold" "100")
    # How many Escapes to send to interrupt a turn (1 = plain interrupt; >1 risks
    # opening Claude's rewind menu - verify on a live pane before raising).
    INTERRUPT_ESCAPES=$(get_tmux_option "@agent-resumer-interrupt-escapes" "1")
    # Notice typed into the paused pane's input box (not submitted).
    CREDIT_NOTICE=$(get_tmux_option "@agent-resumer-credit-notice" "[Credit usage disabled - enable in resumer options]")
    # Seconds of random jitter added to each scheduled retry so a global reset does
    # not release every paused agent simultaneously.
    RESUME_JITTER=$(get_tmux_option "@agent-resumer-resume-jitter" "30")
    # Claude Code vim-mode input: auto (detect from pane), on, or off. In vim mode
    # text must be typed in insert state or it is eaten as normal-mode commands.
    VIM_MODE=$(get_tmux_option "@agent-resumer-vim-mode" "auto")
    DEBUG_LOG=$(get_tmux_option "@agent-resumer-debug-log" "1")

    cat > "${cache}.tmp" <<EOF
ENABLED='$ENABLED'
COLOR='$COLOR'
ICON_WAITING='$ICON_WAITING'
ICON_GAVEUP='$ICON_GAVEUP'
USAGE_BACKOFF_FLOOR='$USAGE_BACKOFF_FLOOR'
SPEND_BACKOFF_FLOOR='$SPEND_BACKOFF_FLOOR'
BACKOFF_CAP='$BACKOFF_CAP'
USAGE_RETRY_CAP='$USAGE_RETRY_CAP'
SPEND_RETRY_CAP='$SPEND_RETRY_CAP'
RESUME_PROMPT='$RESUME_PROMPT'
WARN_SESSION='$WARN_SESSION'
WARN_WEEKLY='$WARN_WEEKLY'
WARN_CREDITS='$WARN_CREDITS'
IDLE_GRACE='$IDLE_GRACE'
CAFFEINATE='$CAFFEINATE'
NTFY_TOPIC='$NTFY_TOPIC'
ALLOW_CREDITS='$ALLOW_CREDITS'
CREDIT_THRESHOLD='$CREDIT_THRESHOLD'
INTERRUPT_ESCAPES='$INTERRUPT_ESCAPES'
CREDIT_NOTICE='$CREDIT_NOTICE'
RESUME_JITTER='$RESUME_JITTER'
VIM_MODE='$VIM_MODE'
DEBUG_LOG='$DEBUG_LOG'
EOF
    mv -f "${cache}.tmp" "$cache"
}

check_tmux_version() {
    local required="${1:-3.0}"
    local current
    current=$(tmux -V 2>/dev/null | sed 's/[^0-9.]//g') || return 1
    [[ -z "$current" ]] && return 1
    local cur_major cur_minor req_major req_minor
    cur_major="${current%%.*}"
    cur_minor="${current#*.}"; cur_minor="${cur_minor%%.*}"
    req_major="${required%%.*}"
    req_minor="${required#*.}"; req_minor="${req_minor%%.*}"
    if [[ "$cur_major" -gt "$req_major" ]]; then return 0; fi
    if [[ "$cur_major" -eq "$req_major" && "$cur_minor" -ge "$req_minor" ]]; then return 0; fi
    return 1
}

ensure_tmux_version() {
    if ! check_tmux_version "3.0"; then
        echo "tmux-agent-resumer requires tmux 3.0+" >&2
        return 1
    fi
}
