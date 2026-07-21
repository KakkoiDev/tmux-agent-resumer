#!/usr/bin/env bash
set -euo pipefail

# tmux-agent-resumer - detect Claude Code agents that died on an API limit
# (HTTP 429) and resume them via poll-and-retry with backoff.
#
# SCAFFOLD STATE (see ~/.claude/plans/we-have-a-harness-jiggly-pascal.md):
#   IMPLEMENTED (safe, no pane side effects):
#     - detect-file : pure analyzer, reads a transcript, prints NONE|spend|usage
#     - hook        : OBSERVATIONAL ONLY - logs whether the hook fired and whether
#                     a 429 was seen in the transcript. Writes no state, types nothing.
#     - init/status-bar/refresh/cleanup plumbing + limited-table schema
#   HELD until the reproduction gate is satisfied (do NOT enable blindly):
#     - the limited-row state machine (insert/backoff/reschedule)
#     - cmd_retry's `tmux send-keys` resume  (guarded by @agent-resumer-enabled, default off)
#   Reproduction gate: confirm Stop/StopFailure actually fires on a 429 (check the
#   debug log after a real limit hit) and observe the pane state before wiring resume.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/helpers.sh"

RESUMER_DIR="${RESUMER_DIR:-$HOME/.tmux-agent-resumer}"
DB="${DB:-$RESUMER_DIR/resumer.db}"
CACHE="${CACHE:-$RESUMER_DIR/status_cache}"
USAGE_JSON="${USAGE_JSON:-$RESUMER_DIR/usage.json}"
USAGE_TTL="${USAGE_TTL:-60}"          # seconds; reuse cached usage.json within this window
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-Claude Code-credentials}"
USAGE_URL="${USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
TRACKER_DB="${TRACKER_DB:-$HOME/.tmux-agent-tracker/tracker.db}"

sql() { printf '.timeout 100\n%s\n' "$*" | sqlite3 "$DB"; }
sql_esc() { local q="'"; printf '%s' "${1//$q/$q$q}"; }

_debug_log() {
    [[ "${DEBUG_LOG:-1}" == "1" ]] || return 0
    mkdir -p "$RESUMER_DIR"
    local _log="$RESUMER_DIR/debug.log"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$_log"
    local _lc
    _lc=$(wc -l < "$_log" 2>/dev/null) || return 0
    if [[ "${_lc:-0}" -gt 1500 ]]; then
        tail -n 1000 "$_log" > "$_log.tmp" && mv -f "$_log.tmp" "$_log"
    fi
}

# Flat "key":"value" extraction (no jq at runtime). Same as tracker's _json_val.
_json_val() {
    local _t="${1#*\"$2\":\"}"
    [[ "$_t" == "$1" ]] && return
    printf '%s' "${_t%%\"*}"
}

_load_config_fast() {
    [[ -n "${ENABLED:-}" ]] && return 0
    local _cc="$RESUMER_DIR/config_cache"
    if [[ -f "$_cc" ]]; then source "$_cc"; else load_config 2>/dev/null || true; fi
}

# ── pure detection logic (unit-tested; no side effects) ───────────────

# Echo the raw JSONL line and return 0 iff the transcript's LAST assistant
# record is a 429 limit hit (i.e. the session is currently stuck, not recovered).
# Checking the last *assistant* record - not the last error line - means a
# session that 429'd then recovered reads as NONE.
# Matcher tolerates optional post-colon spacing; real transcripts are compact
# JSONL - confirm the exact shape against a live transcript at the repro gate.
_detect_limit_line() {
    local tp="$1"
    [[ -f "$tp" ]] || return 1
    local line
    line=$(tail -n 80 "$tp" 2>/dev/null | grep -E '"type": ?"assistant"' | tail -n 1) || true
    [[ -z "$line" ]] && return 1
    [[ "$line" =~ \"isApiErrorMessage\":\ ?true ]] || return 1
    [[ "$line" =~ \"apiErrorStatus\":\ ?429 ]] || return 1
    printf '%s' "$line"
}

# Classify the limit type from the human-facing message text.
# Strings sourced from Claude Code v2.1.216 binary (see plan doc section 4).
_classify_limit() {
    local text="$1"
    case "$text" in
        *"monthly spend limit"*|*"out of usage"*|*"usage allocation has been disabled"*|*"usage limit is set to"*|*"add funds to continue"*)
            echo "spend" ;;
        *"session limit"*|*"weekly limit"*|*"Opus limit"*|*"Sonnet limit"*|*"Fable 5 limit"*|*"usage credit limit"*)
            echo "usage" ;;
        *)
            echo "unknown" ;;
    esac
}

# Exponential backoff with cap. Args: current_secs limit_type -> next_secs.
_next_backoff() {
    local cur="$1" type="${2:-usage}"
    local cap="${BACKOFF_CAP:-3600}"
    local next=$(( cur * 2 ))
    [[ "$next" -gt "$cap" ]] && next="$cap"
    printf '%s' "$next"
}

# ── commands ──────────────────────────────────────────────────────────

cmd_init() {
    mkdir -p "$RESUMER_DIR"
    sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=100;
CREATE TABLE IF NOT EXISTS limited (
    session_id      TEXT PRIMARY KEY,
    tmux_pane       TEXT,
    tmux_target     TEXT,
    limit_type      TEXT NOT NULL,
    transcript_path TEXT NOT NULL,
    resume_prompt   TEXT,
    retry_count     INTEGER NOT NULL DEFAULT 0,
    backoff_secs    INTEGER NOT NULL DEFAULT 120,
    next_retry_at   INTEGER,
    status          TEXT NOT NULL DEFAULT 'waiting'
        CHECK(status IN ('waiting','retrying','resumed','gaveup')),
    detected_at     INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at      INTEGER NOT NULL DEFAULT (unixepoch())
);
SQL
    echo "Initialized: $DB"
}

# Safe analyzer. Reads a transcript file, prints NONE or "<type> <message>".
# Types nothing, writes no DB. Use for tests and for hand-checking a transcript.
cmd_detect_file() {
    local tp="${1:?Usage: resumer.sh detect-file <transcript.jsonl>}"
    local line type text
    if ! line=$(_detect_limit_line "$tp"); then
        echo "NONE"
        return 0
    fi
    text=$(_json_val "$line" "text")
    type=$(_classify_limit "$text")
    printf '%s\t%s\n' "$type" "$text"
}

# OBSERVATIONAL hook. Confirms whether Stop/StopFailure fires on a 429 and
# whether detection matches. Writes NO state and types NOTHING - this is the
# reproduction-gate instrument, not the resume path.
cmd_hook() {
    _load_config_fast
    local event="${1:-}"
    local json
    read -r json || true
    [[ -z "$json" ]] && json='{}'

    local sid tp
    sid=$(_json_val "$json" "session_id")
    tp=$(_json_val "$json" "transcript_path")

    if [[ -z "$tp" ]]; then
        _debug_log "HOOK $event sid=${sid:-?} no transcript_path in payload"
        return 0
    fi

    local line type
    if line=$(_detect_limit_line "$tp"); then
        type=$(_classify_limit "$(_json_val "$line" "text")")
        _debug_log "HOOK $event sid=${sid:-?} DETECTED 429 type=$type pane=${TMUX_PANE:-none} (observational; resume held)"
    else
        _debug_log "HOOK $event sid=${sid:-?} no 429 in transcript tail"
    fi
    # HELD: limited-row insert + backoff schedule go here once the gate passes.
    return 0
}

# HELD: actual resume. Refuses until the reproduction gate is cleared AND the
# user flips @agent-resumer-enabled on. No `tmux send-keys` ships in the scaffold.
cmd_retry() {
    local sid="${1:?Usage: resumer.sh retry <session_id>}"
    _load_config_fast
    if [[ "${ENABLED:-off}" != "on" ]]; then
        _debug_log "RETRY sid=$sid refused: @agent-resumer-enabled is off (repro gate)"
        return 0
    fi
    _debug_log "RETRY sid=$sid: resume path not implemented in scaffold (repro gate)"
    # HELD implementation outline (do not enable before repro):
    #   1. read limited row; bail if status != waiting.
    #   2. guard: pane exists + _has_agent_child + pane is NOT the focused pane.
    #   3. tmux send-keys -t <pane> "$RESUME_PROMPT" Enter ; status=retrying.
    #   4. next hook re-detects; 429 -> _next_backoff + reschedule; clean -> resumed.
    return 0
}

# ── status bar render ─────────────────────────────────────────────────

_write_cache() {
    _load_config_fast
    local counts waiting gaveup
    counts=$(sql "SELECT
        COALESCE(SUM(CASE WHEN status IN ('waiting','retrying') THEN 1 ELSE 0 END),0) || '|' ||
        COALESCE(SUM(CASE WHEN status='gaveup' THEN 1 ELSE 0 END),0)
        FROM limited;" 2>/dev/null || echo "0|0")
    waiting="${counts%%|*}"; gaveup="${counts#*|}"
    waiting="${waiting:-0}"; gaveup="${gaveup:-0}"

    local final=""
    if [[ "$waiting" -gt 0 || "$gaveup" -gt 0 ]]; then
        final="#[fg=${COLOR:-yellow}]${waiting}${ICON_WAITING:-~}"
        [[ "$gaveup" -gt 0 ]] && final+=" ${gaveup}${ICON_GAVEUP:-x}"
        final+="#[default]"
    fi
    printf '%s' "$final" > "$CACHE.tmp" 2>/dev/null || true
    mv -f "$CACHE.tmp" "$CACHE" 2>/dev/null || true
    tmux set -gq @agent-resumer-status "$final" 2>/dev/null || true
}

cmd_status_bar() { [[ -f "$CACHE" ]] && cat "$CACHE" || true; }
cmd_refresh() { [[ -f "$DB" ]] && _write_cache 2>/dev/null || true; }

# ── cleanup ───────────────────────────────────────────────────────────

cmd_cleanup() {
    [[ -f "$DB" ]] || return 0
    # Drop resumed rows and rows whose pane no longer exists.
    sql "DELETE FROM limited WHERE status='resumed';" 2>/dev/null || true
    local live_panes
    live_panes=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | paste -sd, - 2>/dev/null || true)
    if [[ -n "$live_panes" ]]; then
        local in_list
        in_list=$(printf "'%s'," ${live_panes//,/ }); in_list="${in_list%,}"
        sql "DELETE FROM limited WHERE tmux_pane NOT IN ($in_list) AND tmux_pane != '';" 2>/dev/null || true
    fi
}

# ── usage fetch (hybrid: endpoint -> local cache -> stale) ────────────

# Echo a path to a usage JSON file (endpoint response OR ~/.claude.json cache),
# or return 1 if no data. Reuses a fresh $USAGE_JSON within $USAGE_TTL to avoid
# re-reading the keychain / re-hitting the network on every modal open.
cmd_usage_fetch() {
    mkdir -p "$RESUMER_DIR"
    if [[ -f "$USAGE_JSON" ]]; then
        local age; age=$(( $(date +%s) - $(_file_mtime "$USAGE_JSON" 2>/dev/null || echo 0) ))
        if [[ "$age" -lt "$USAGE_TTL" ]]; then printf '%s' "$USAGE_JSON"; return 0; fi
    fi

    # 1) live endpoint with the keychain OAuth token
    local raw tok status
    raw=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)
    if [[ -n "$raw" ]]; then
        tok=$(printf '%s' "$raw" | python3 -c 'import json,sys;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null || true)
        if [[ -n "$tok" ]]; then
            status=$(curl -sS -m 10 -o "$USAGE_JSON.tmp" -w '%{http_code}' \
                -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
                "$USAGE_URL" 2>/dev/null || echo 000)
            if [[ "$status" == "200" ]]; then
                mv -f "$USAGE_JSON.tmp" "$USAGE_JSON"
                _debug_log "usage fetched via endpoint (200)"
                printf '%s' "$USAGE_JSON"; return 0
            fi
            rm -f "$USAGE_JSON.tmp" 2>/dev/null || true
            _debug_log "usage endpoint failed status=$status (token expired? falling back)"
        fi
    fi

    # 2) fallback: ~/.claude.json cachedUsageUtilization.utilization (same shape)
    local cj="$HOME/.claude.json" util
    if [[ -f "$cj" ]]; then
        util=$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
u=(d.get("cachedUsageUtilization") or {}).get("utilization")
print(json.dumps(u) if u else "")' "$cj" 2>/dev/null || true)
        if [[ -n "$util" && "$util" != "null" ]]; then
            printf '%s' "$util" > "$USAGE_JSON.tmp" && mv -f "$USAGE_JSON.tmp" "$USAGE_JSON"
            _debug_log "usage from ~/.claude.json cache"
            printf '%s' "$USAGE_JSON"; return 0
        fi
    fi

    # 3) last resort: stale endpoint cache if we have one
    [[ -f "$USAGE_JSON" ]] && { _debug_log "usage stale cache"; printf '%s' "$USAGE_JSON"; return 0; }
    return 1
}

# Render usage JSON into display lines. Handles both the endpoint response and
# the cachedUsageUtilization.utilization object (identical shape).
_usage_lines() {
    python3 - "$1" <<'PY' 2>/dev/null || true
import json,sys,datetime
try:
    d=json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
now=datetime.datetime.now(datetime.timezone.utc)
def fmt(iso):
    if not iso: return "?"
    try: t=datetime.datetime.fromisoformat(iso.replace("Z","+00:00"))
    except Exception: return "?"
    m=int((t-now).total_seconds()//60)
    if m<0: rel="now"
    elif m<60: rel=f"{m}m"
    elif m<1440: rel=f"{m//60}h{m%60:02d}m"
    else: rel=f"{m//1440}d{(m%1440)//60}h"
    return t.astimezone().strftime("%a %H:%M")+f" ({rel})"
def pct(x):
    try: return int(round(float(x)))
    except Exception: return 0
out=[]
fh=d.get("five_hour") or {}
if fh: out.append(f"Session  {pct(fh.get('utilization',0))}%   resets {fmt(fh.get('resets_at'))}")
sd=d.get("seven_day") or {}
if sd: out.append(f"Weekly   {pct(sd.get('utilization',0))}%   resets {fmt(sd.get('resets_at'))}")
for l in d.get("limits",[]) or []:
    if l.get("kind")=="weekly_scoped":
        nm=((l.get("scope") or {}).get("model") or {}).get("display_name") or "model"
        out.append(f"  {nm} weekly: {pct(l.get('percent',0))}%")
sp=d.get("spend") or {}
if sp and sp.get("enabled"):
    u=sp.get("used") or {}; li=sp.get("limit") or {}
    ue=10**int(u.get("exponent",2) or 2); le=10**int(li.get("exponent",2) or 2)
    cur=u.get("currency","")
    out.append(f"Credits  {pct(sp.get('percent',0))}%   ({u.get('amount_minor',0)/ue:.2f}/{li.get('amount_minor',0)/le:.2f} {cur})")
for x in out: print(x)
PY
}

# ── modal (<prefix>+R): usage + paused agents, navigate to a paused pane ──

# Derive the transcript path for a Claude session id (glob is robust vs cwd mangling).
_transcript_for() {
    local sid="$1"
    ls "$HOME/.claude/projects"/*/"$sid".jsonl 2>/dev/null | head -1 || true
}

cmd_menu() {
    _load_config_fast
    local args=(-T "Usage & Paused Agents")

    local uf
    if uf=$(cmd_usage_fetch); then
        local any=0 ul
        while IFS= read -r ul; do
            [[ -z "$ul" ]] && continue
            any=1
            args+=("$ul" "" "")   # empty command => non-selectable header line
        done < <(_usage_lines "$uf")
        [[ "$any" -eq 0 ]] && args+=("(usage data empty)" "" "")
    else
        args+=("usage unavailable (open /usage once, or re-auth)" "" "")
    fi

    args+=("" "" "")   # separator

    local found=0
    if [[ -f "$TRACKER_DB" ]]; then
        local sid target project tp line type label
        while IFS='|' read -r sid target project; do
            [[ -z "$sid" ]] && continue
            tp=$(_transcript_for "$sid")
            [[ -z "$tp" ]] && continue
            if line=$(_detect_limit_line "$tp"); then
                type=$(_classify_limit "$(_json_val "$line" "text")")
                found=$((found+1))
                label="! ${project:-?} [${type}]"
                if [[ -n "$target" ]]; then
                    args+=("$label" "" "run-shell '$SCRIPTS_DIR/resumer.sh goto ${target}'")
                else
                    args+=("$label (no pane)" "" "")
                fi
            fi
        done < <(sqlite3 -separator '|' "$TRACKER_DB" \
            "SELECT session_id, COALESCE(tmux_target,''), COALESCE(project_name,'')
             FROM sessions WHERE COALESCE(agent_type,'')='' AND COALESCE(agent_client,'claude')='claude';" 2>/dev/null)
    else
        args+=("(tmux-agent-tracker DB not found - can't list panes)" "" "")
    fi
    [[ "$found" -eq 0 ]] && args+=("No paused agents" "" "")

    args+=("" "" "")
    args+=("Refresh" "r" "run-shell '$SCRIPTS_DIR/resumer.sh menu'")
    args+=("Quit" "q" "")

    # Test seam: print the menu instead of popping it (no attached client needed).
    if [[ "${RESUMER_MENU_DRYRUN:-0}" == "1" ]]; then
        printf '%s\n' "${args[@]}"
        return 0
    fi
    tmux display-menu "${args[@]}"
}

# Jump to a pane. Target is 'session:window.pane'. Same moves as the tracker.
cmd_goto() {
    local target="${1:?Usage: resumer.sh goto <session:window.pane>}"
    local sess="${target%%:*}" win="${target%.*}"
    tmux switch-client -t "$sess" 2>/dev/null || true
    tmux select-window -t "$win" 2>/dev/null || true
    tmux select-pane -t "$target" 2>/dev/null || true
    _debug_log "goto target=$target"
}

# ── main ──────────────────────────────────────────────────────────────
# Guard so tests can `source` this file and exercise the pure functions
# without tripping the dispatcher.

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    case "${1:-}" in
        init)        cmd_init ;;
        hook)        cmd_hook "${2:?Usage: resumer.sh hook <event>}" ;;
        detect-file) cmd_detect_file "${2:-}" ;;
        retry)       cmd_retry "${2:-}" ;;
        status-bar)  cmd_status_bar ;;
        refresh)     cmd_refresh ;;
        cleanup)     cmd_cleanup ;;
        menu)        cmd_menu ;;
        usage)       cmd_usage_fetch >/dev/null && _usage_lines "$USAGE_JSON" ;;
        goto)        cmd_goto "${2:-}" ;;
        *) echo "Usage: resumer.sh {init|hook <event>|detect-file <path>|retry <sid>|status-bar|refresh|cleanup|menu|usage|goto <target>}" >&2
           exit 1 ;;
    esac
fi
