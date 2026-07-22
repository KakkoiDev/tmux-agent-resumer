#!/usr/bin/env bash
set -euo pipefail

# tmux-agent-resumer - detect Claude Code agents that died on an API limit
# (HTTP 429) and resume them via poll-and-retry with backoff.
#
# STATE (see ~/.claude/plans/we-have-a-harness-jiggly-pascal.md):
#   Always safe (no pane side effects):
#     - detect-file : pure analyzer, prints NONE|spend|usage
#     - hook        : logs whether the hook fired + whether a 429 was seen
#     - usage/menu  : <prefix>+R modal (usage %, reset, weekly, credits) + paused list
#     - refresh     : status badge, incl. SPILL alert when session/weekly/credits near cap (#2)
#   #3 auto-resume (cmd_scan/cmd_retry/hook-enqueue) types "$RESUME_PROMPT" (default
#   "resume") into the paused pane to re-issue the request once its window resets.
#   It cannot bypass anything: the API still enforces the limit server-side; a retry
#   while still limited just 429s again and backs off. For usage/rate limits the first
#   retry is scheduled at the real reset time (from /api/oauth/usage). Gated behind
#   @agent-resumer-enabled (default off) with an active-pane guard (won't type into the
#   pane you're using) and a retry cap. UNVERIFIED until a real hit: that Stop/StopFailure
#   fires on a 429, and that "resume"+Enter is what the post-429 TUI needs. Confirm, then enable.

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/helpers.sh"

RESUMER_DIR="${RESUMER_DIR:-$HOME/.tmux-agent-resumer}"
DB="${DB:-$RESUMER_DIR/resumer.db}"
CACHE="${CACHE:-$RESUMER_DIR/status_cache}"
USAGE_JSON="${USAGE_JSON:-$RESUMER_DIR/usage.json}"
USAGE_TTL="${USAGE_TTL:-300}"         # seconds; reuse cached usage.json within this window
SCAN_INTERVAL="${SCAN_INTERVAL:-30}"  # seconds; min gap between background limit scans
KEYCHAIN_SERVICE="${KEYCHAIN_SERVICE:-Claude Code-credentials}"
USAGE_URL="${USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
TRACKER_DB="${TRACKER_DB:-$HOME/.tmux-agent-tracker/tracker.db}"

sql() { printf '.timeout 100\n%s\n' "$*" | sqlite3 "$DB"; }
sql_esc() { local q="'"; printf '%s' "${1//$q/$q$q}"; }

# Atomic mkdir lock (macOS has no flock). Returns 0 if acquired. Steals a lock
# older than 120s so a killed holder can't deadlock. _unlock releases it.
_try_lock() {
    local d="$RESUMER_DIR/.lock.$1"
    mkdir -p "$RESUMER_DIR" 2>/dev/null || true
    if mkdir "$d" 2>/dev/null; then return 0; fi
    local age; age=$(( $(date +%s) - $(_file_mtime "$d" 2>/dev/null || echo 0) ))
    if [[ "$age" -ge 120 ]]; then rmdir "$d" 2>/dev/null || true; mkdir "$d" 2>/dev/null && return 0; fi
    return 1
}
_unlock() { rmdir "$RESUMER_DIR/.lock.$1" 2>/dev/null || true; }

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

# Phone push via ntfy.sh. No-op unless @agent-resumer-ntfy-topic is set. #3.
_notify() {
    _load_config_fast
    [[ -n "${NTFY_TOPIC:-}" ]] || return 0
    ( curl -s -m 5 -d "$1" "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 & )
}

# Flat "key":"value" extraction (no jq at runtime). Same as tracker's _json_val.
_json_val() {
    local _t="${1#*\"$2\":\"}"
    [[ "$_t" == "$1" ]] && return
    printf '%s' "${_t%%\"*}"
}

_load_config_fast() {
    [[ -n "${ENABLED:-}" ]] && return 0
    # Delegate to load_config so the 60s staleness check is honored and the cache
    # is rewritten when stale - otherwise a direct `tmux set @agent-resumer-*`
    # would never propagate (the cache was sourced unconditionally, forever).
    load_config 2>/dev/null || true
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
CREATE TABLE IF NOT EXISTS guard_state (
    k TEXT PRIMARY KEY,
    v REAL
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
        _debug_log "HOOK $event sid=${sid:-?} DETECTED 429 type=$type pane=${TMUX_PANE:-none} enabled=${ENABLED:-off}"
        if [[ "${ENABLED:-off}" == "on" && -n "${sid:-}" ]]; then
            _enqueue_limited "$sid" "" "${TMUX_PANE:-}" "$type" "$tp"
        fi
    else
        _debug_log "HOOK $event sid=${sid:-?} no 429 in transcript tail"
    fi
    return 0
}

# ── resume state machine (#3) - gated behind @agent-resumer-enabled ───

# Seconds until a given usage window resets, from the cached usage JSON.
# $1 = window key (five_hour | seven_day). Lets a usage-limit resume be scheduled
# at the REAL reset instead of blind polling, and against the CORRECT window so a
# weekly limit is not retried on the 5-hour cadence (and exhausted before it lifts).
_seconds_until_reset() {
    local key="${1:-five_hour}"
    [[ -f "$USAGE_JSON" ]] || return 1
    python3 - "$USAGE_JSON" "$key" <<'PY' 2>/dev/null || true
import json,sys,datetime
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
r=(d.get(sys.argv[2]) or {}).get("resets_at")
if not r: sys.exit(0)
try: t=datetime.datetime.fromisoformat(r.replace("Z","+00:00"))
except Exception: sys.exit(0)
print(max(int((t-datetime.datetime.now(datetime.timezone.utc)).total_seconds()),0))
PY
}
_seconds_until_session_reset() { _seconds_until_reset five_hour; }

# Pick the usage window (five_hour|seven_day) implied by a limit message.
_reset_window_for_text() {
    case "$1" in
        *"weekly limit"*|*"Opus limit"*|*"Sonnet limit"*|*"Fable 5 limit"*) echo "seven_day" ;;
        *) echo "five_hour" ;;
    esac
}

_schedule_retry() {
    local sid="$1" delay="$2"
    # Jitter so N agents released by the same account-global reset don't all fire
    # at once and re-trigger the limit. 0..RESUME_JITTER seconds added.
    local jmax="${RESUME_JITTER:-30}"
    if [[ "${jmax:-0}" -gt 0 ]] 2>/dev/null; then
        delay=$(( delay + RANDOM % (jmax + 1) ))
    fi
    tmux run-shell -b "sleep $delay && $SCRIPTS_DIR/resumer.sh retry $sid" 2>/dev/null || true
}

# Keep the Mac awake while any agent is paused, so the scheduled resume timer
# survives idle sleep (Claude's own caffeinate lapses once the agent stalls).
# Holds ONE continuous `caffeinate -i` for the whole wait (no 15-min gaps) and
# ties its lifetime to the tmux server via -w, so it can't outlive tmux or pin
# the machine awake forever. Released (killed) the moment nothing is paused.
_caffeinate_sync() {
    _load_config_fast
    [[ "${CAFFEINATE:-on}" == "on" ]] || return 0
    # Serialize the check-spawn-record sequence so two concurrent syncs can't both
    # spawn a caffeinate (leaking an unrecorded one). If busy, another sync has it.
    _try_lock caffeinate || return 0
    local pidf="$RESUMER_DIR/caffeinate.pid" n running="" p
    n=$(sql "SELECT COUNT(*) FROM limited WHERE status IN ('waiting','retrying');" 2>/dev/null || echo 0)
    if [[ -f "$pidf" ]]; then
        p=$(cat "$pidf" 2>/dev/null || true)
        if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then running="$p"; else rm -f "$pidf"; fi
    fi
    if [[ "${n:-0}" -gt 0 && -z "$running" ]]; then
        # Hold until we kill it or the tmux server exits (whichever first).
        local tpid; tpid=$(tmux display-message -p '#{pid}' 2>/dev/null || true)
        if [[ -n "$tpid" ]]; then
            caffeinate -i -w "$tpid" >/dev/null 2>&1 &
        else
            caffeinate -i -t 3600 >/dev/null 2>&1 &   # fallback: bounded, no tmux
        fi
        echo $! > "$pidf"
        _debug_log "caffeinate on (pid $!, held for tmux $tpid) - $n paused agent(s)"
    elif [[ "${n:-0}" -eq 0 && -n "$running" ]]; then
        kill "$running" 2>/dev/null || true
        rm -f "$pidf"
        _debug_log "caffeinate off - no paused agents"
    fi
    _unlock caffeinate
}

# Record a limited session and schedule its first retry. No-op if already active.
_enqueue_limited() {
    local sid="$1" target="$2" pane="$3" type="$4" tp="$5"
    _load_config_fast
    [[ -f "$DB" ]] || cmd_init >/dev/null 2>&1
    [[ -z "$target" && -n "$pane" ]] && target=$(tmux display-message -t "$pane" \
        -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)

    local floor="${USAGE_BACKOFF_FLOOR:-120}"
    [[ "$type" == "spend" ]] && floor="${SPEND_BACKOFF_FLOOR:-1800}"
    local delay="$floor"
    if [[ "$type" == "usage" ]]; then
        # Schedule the first retry at the reset of the CORRECT window (weekly limits
        # reset on the 7-day clock, not the 5-hour one).
        local win rs mtext=""
        [[ -n "$tp" ]] && mtext=$(_json_val "$(_detect_limit_line "$tp" 2>/dev/null || true)" "text")
        win=$(_reset_window_for_text "$mtext")
        rs=$(_seconds_until_reset "$win" 2>/dev/null || true)
        [[ -n "$rs" && "$rs" -gt 0 ]] 2>/dev/null && delay=$(( rs + 15 ))
    fi
    local now; now=$(date +%s)
    local rp="${RESUME_PROMPT:-resume}"
    local esid; esid=$(sql_esc "$sid")
    # Atomic claim: insert (or replace a stale 'resumed' row) ONLY if no active or
    # gaveup row exists for this session, then report changes() from the SAME
    # connection. Prevents two concurrent callers both scheduling a timer (double
    # 'resume'), and stops cmd_scan resurrecting a 'gaveup' row past the retry cap.
    local claimed
    claimed=$(sql "INSERT OR REPLACE INTO limited
             (session_id,tmux_pane,tmux_target,limit_type,transcript_path,
              resume_prompt,retry_count,backoff_secs,next_retry_at,status,detected_at,updated_at)
         SELECT '$esid','$(sql_esc "$pane")','$(sql_esc "$target")','$(sql_esc "$type")',
             '$(sql_esc "$tp")','$(sql_esc "$rp")',0,$floor,$((now+delay)),'waiting',$now,$now
         WHERE NOT EXISTS (SELECT 1 FROM limited
             WHERE session_id='$esid' AND status IN ('waiting','retrying','gaveup'));
         SELECT changes();")
    [[ "$claimed" == "1" ]] || return 0
    _debug_log "enqueue sid=$sid type=$type pane=$pane first-retry=${delay}s"
    _notify "resumer: agent hit ${type} limit (pane ${pane:-?}). Waiting; will auto-resume at reset."
    _schedule_retry "$sid" "$delay"
    _caffeinate_sync
}

# One retry tick for a limited session. Sends the resume keys iff still limited,
# pane alive, and not the pane the user is currently looking at.
cmd_retry() {
    local sid="${1:?Usage: resumer.sh retry <session_id>}"
    _load_config_fast
    [[ -f "$DB" ]] || return 0
    if [[ "${ENABLED:-off}" != "on" ]]; then
        _debug_log "RETRY sid=$sid refused: @agent-resumer-enabled off"
        return 0
    fi
    local info
    # char(31) (unit separator, non-whitespace) so EMPTY fields survive the split -
    # credit-guard rows have empty transcript_path; a tab/space IFS would collapse
    # adjacent delimiters and shift every following field.
    info=$(sql "SELECT status||char(31)||COALESCE(tmux_pane,'')||char(31)||limit_type||char(31)||transcript_path||char(31)||retry_count||char(31)||backoff_secs||char(31)||COALESCE(resume_prompt,'resume')
               FROM limited WHERE session_id='$(sql_esc "$sid")';" 2>/dev/null || true)
    [[ -z "$info" ]] && return 0
    local st pane type tp rc backoff rp
    IFS=$'\x1f' read -r st pane type tp rc backoff rp <<< "$info"
    [[ "$st" == "waiting" || "$st" == "retrying" ]] || { _debug_log "RETRY sid=$sid skip status=$st"; return 0; }
    local now; now=$(date +%s)

    if [[ -z "$pane" ]] || ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane"; then
        sql "UPDATE limited SET status='gaveup',updated_at=$now WHERE session_id='$(sql_esc "$sid")';"
        _debug_log "RETRY sid=$sid gaveup: pane '$pane' gone"; return 0
    fi
    local ppid; ppid=$(tmux display-message -t "$pane" -p '#{pane_pid}' 2>/dev/null || true)
    if [[ -n "$ppid" ]] && ! _has_agent_child "$ppid"; then
        sql "UPDATE limited SET status='gaveup',updated_at=$now WHERE session_id='$(sql_esc "$sid")';"
        _debug_log "RETRY sid=$sid gaveup: no live agent in pane"; return 0
    fi
    # Active-pane guard: don't type while you're actually at the keyboard on this
    # pane. "Watched" = pane_active AND window_active AND a client attached to its
    # session. But if that client has been idle past IDLE_GRACE (you walked away
    # without switching panes), resume anyway - deferring forever defeats the point.
    local viewing; viewing=$(tmux display-message -t "$pane" -p '#{&&:#{pane_active},#{&&:#{window_active},#{session_attached}}}' 2>/dev/null || echo 0)
    if [[ "$viewing" == "1" ]]; then
        local psess last_act idle grace
        psess=$(tmux display-message -t "$pane" -p '#{session_name}' 2>/dev/null || true)
        # Filter by the WHOLE session name server-side (a name may contain spaces,
        # which an awk field-split would break, silently failing the guard open).
        last_act=$(tmux list-clients -f "#{==:#{client_session},$psess}" \
            -F '#{client_activity}' 2>/dev/null | sort -n | tail -1)
        grace="${IDLE_GRACE:-60}"
        if [[ -n "$last_act" ]]; then
            idle=$(( now - last_act ))
            if [[ "$idle" -lt "$grace" ]]; then
                _debug_log "RETRY sid=$sid deferred: pane watched, client active ${idle}s ago (< ${grace}s)"
                _schedule_retry "$sid" "$backoff"; return 0
            fi
            _debug_log "RETRY sid=$sid pane watched but client idle ${idle}s (>= ${grace}s) - resuming"
        fi
    fi
    # credit-guard rows resume on session RESET (utilization drop), not a 429 clear.
    if [[ "$type" == "credit-guard" ]]; then
        local su sui; su=$(_session_util); sui=${su%.*}
        if [[ -n "$su" && "${sui:-100}" -lt "${CREDIT_THRESHOLD:-100}" ]]; then
            tmux send-keys -t "$pane" C-u 2>/dev/null || true       # clear the typed notice
            tmux send-keys -t "$pane" "$rp" Enter 2>/dev/null || true
            sql "UPDATE limited SET status='resumed',updated_at=$now WHERE session_id='$(sql_esc "$sid")';"
            _debug_log "credit-guard RESUME sid=$sid (session back to ${su}%)"
            _notify "resumer: session reset - resumed agent (pane ${pane})."; return 0
        fi
        local nbg; nbg=$(_next_backoff "$backoff" usage)
        sql "UPDATE limited SET status='waiting',retry_count=$((rc+1)),backoff_secs=$nbg,next_retry_at=$((now+nbg)),updated_at=$now WHERE session_id='$(sql_esc "$sid")';"
        _debug_log "credit-guard sid=$sid still maxed (${su:-?}%), wait ${nbg}s"
        _schedule_retry "$sid" "$nbg"; return 0
    fi
    # Cleared already?
    if ! _detect_limit_line "$tp" >/dev/null; then
        sql "UPDATE limited SET status='resumed',updated_at=$now WHERE session_id='$(sql_esc "$sid")';"
        _debug_log "RETRY sid=$sid RESUMED (transcript no longer 429)"
        _notify "resumer: agent resumed (pane ${pane})."; return 0
    fi
    local cap="${USAGE_RETRY_CAP:-12}"; [[ "$type" == "spend" ]] && cap="${SPEND_RETRY_CAP:-48}"
    if [[ "$rc" -ge "$cap" ]]; then
        sql "UPDATE limited SET status='gaveup',updated_at=$now WHERE session_id='$(sql_esc "$sid")';"
        _debug_log "RETRY sid=$sid gaveup: still limited after $cap attempts"
        _notify "resumer: gave up on paused agent (pane ${pane}) after $cap attempts."; return 0
    fi
    # Type the resume prompt into the pane. This only RE-ISSUES the request; the
    # API still enforces the limit - if the window is still closed it 429s again
    # and we back off; once it has reset, the turn continues. No bypass, just the
    # keypress you would make yourself.
    tmux send-keys -t "$pane" "$rp" Enter 2>/dev/null || true
    local nb; nb=$(_next_backoff "$backoff" "$type")
    sql "UPDATE limited SET status='retrying',retry_count=$((rc+1)),backoff_secs=$nb,next_retry_at=$((now+nb)),updated_at=$now
         WHERE session_id='$(sql_esc "$sid")';"
    _debug_log "RETRY sid=$sid sent '$rp' attempt=$((rc+1)) next=${nb}s"
    _schedule_retry "$sid" "$nb"
}

# Hook-independent trigger: scan tracked panes, enqueue any currently limited.
cmd_scan() {
    _load_config_fast
    [[ "${ENABLED:-off}" == "on" ]] || return 0
    [[ -f "$TRACKER_DB" ]] || return 0
    [[ -f "$DB" ]] || cmd_init >/dev/null 2>&1
    local sid target pane tp line type
    while IFS=$'\x1f' read -r sid target pane; do
        [[ -z "$sid" ]] && continue
        tp=$(_transcript_for "$sid")
        [[ -z "$tp" ]] && continue
        if line=$(_detect_limit_line "$tp"); then
            type=$(_classify_limit "$(_json_val "$line" "text")")
            _enqueue_limited "$sid" "$target" "$pane" "$type" "$tp"
        fi
    done < <(sqlite3 -separator $'\x1f' "$TRACKER_DB" \
        "SELECT session_id, COALESCE(tmux_target,''), COALESCE(tmux_pane,'')
         FROM sessions WHERE COALESCE(agent_type,'')='' AND COALESCE(agent_client,'claude')='claude';" 2>/dev/null)
}

# ── credit guard (block paid overage; "Allow usage credit" = the safety toggle) ──

_num_field() {  # $1=usage.json $2=dotted path e.g. five_hour.utilization / spend.percent
    python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
cur=d
for k in sys.argv[2].split('.'):
    cur=(cur or {}).get(k) if isinstance(cur,dict) else None
try: print(float(cur))
except Exception: pass
PY
}
_session_util() { _num_field "$USAGE_JSON" "five_hour.utilization"; }
_credits_pct()  { _num_field "$USAGE_JSON" "spend.percent"; }

# Interrupt only WORKING claude agents (those mid-turn = actually spending
# credits); idle/finished panes spend nothing and are left alone. Sends Escape
# to stop the turn, types the notice into the box (no Enter), enqueues each for
# a free resume at the session reset. Only reached on a fresh crossing into max.
_credit_guard_interrupt() {
    [[ -f "$TRACKER_DB" ]] || return 0
    local reset_secs now delay sid target pane st n=0 esc="${INTERRUPT_ESCAPES:-1}" i
    reset_secs=$(_seconds_until_session_reset 2>/dev/null || echo 0)
    now=$(date +%s)
    delay=$(( ${reset_secs:-0} + 15 )); [[ "$delay" -lt 60 ]] && delay=300
    while IFS=$'\x1f' read -r sid target pane; do
        [[ -z "$sid" || -z "$pane" ]] && continue
        st=$(sql "SELECT status FROM limited WHERE session_id='$(sql_esc "$sid")';" 2>/dev/null || true)
        [[ "$st" == "waiting" || "$st" == "retrying" ]] && continue   # already handled
        i=0; while [[ "$i" -lt "$esc" ]]; do tmux send-keys -t "$pane" Escape 2>/dev/null || true; i=$((i+1)); done
        [[ -n "${CREDIT_NOTICE:-}" ]] && tmux send-keys -t "$pane" "$CREDIT_NOTICE" 2>/dev/null || true  # typed, NOT submitted
        sql "DELETE FROM limited WHERE session_id='$(sql_esc "$sid")';
             INSERT INTO limited (session_id,tmux_pane,tmux_target,limit_type,transcript_path,
                 resume_prompt,retry_count,backoff_secs,next_retry_at,status,detected_at,updated_at)
             VALUES ('$(sql_esc "$sid")','$(sql_esc "$pane")','$(sql_esc "$target")','credit-guard','',
                 'resume',0,$delay,$((now+delay)),'waiting',$now,$now);"
        _schedule_retry "$sid" "$delay"
        n=$((n+1))
    done < <(sqlite3 -separator $'\x1f' "$TRACKER_DB" \
        "SELECT session_id, COALESCE(tmux_target,''), COALESCE(tmux_pane,'')
         FROM sessions WHERE COALESCE(agent_type,'')='' AND COALESCE(agent_client,'claude')='claude'
           AND status='working';" 2>/dev/null)
    _debug_log "credit-guard: interrupted $n working agent(s) at session-max; resume in ${delay}s"
    [[ "$n" -gt 0 ]] && _notify "resumer: session maxed - blocked credit spend on $n agent(s). Free resume at reset."
    _caffeinate_sync
}

# Detect a fresh crossing into session-max and, unless credits are allowed,
# interrupt to avoid paid spend. The baseline lives in guard_state (SQLite), and
# the crossing is claimed atomically so:
#   - the FIRST arm against an already-maxed session is NOT a false crossing
#     (baseline is seeded to current and we return);
#   - two concurrent refreshes cannot both interrupt (only one UPDATE claims it).
cmd_credit_guard() {
    _load_config_fast
    [[ "${ENABLED:-off}" == "on" ]] || return 0
    [[ -f "$DB" ]] || return 0
    [[ -f "$USAGE_JSON" ]] || return 0
    local thr cur seeded
    thr="${CREDIT_THRESHOLD:-100}"
    cur=$(_session_util); [[ -z "$cur" ]] && return 0
    # First arm: no baseline yet -> seed and return (never a crossing).
    seeded=$(sql "INSERT INTO guard_state (k,v) SELECT 'session_util',$cur
                  WHERE NOT EXISTS (SELECT 1 FROM guard_state WHERE k='session_util');
                  SELECT changes();" 2>/dev/null || echo 0)
    [[ "$seeded" == "1" ]] && { _debug_log "credit-guard: baseline seeded at ${cur}% (no crossing)"; return 0; }
    # Atomically claim an upward crossing (prev<thr && cur>=thr): only one caller wins.
    local crossed
    crossed=$(sql "UPDATE guard_state SET v=$cur
                   WHERE k='session_util' AND v < $thr AND $cur >= $thr;
                   SELECT changes();" 2>/dev/null || echo 0)
    # Always keep the baseline current for the next comparison (idempotent).
    sql "UPDATE guard_state SET v=$cur WHERE k='session_util';" 2>/dev/null || true
    [[ "$crossed" == "1" ]] || return 0
    # Allowing credits (emergency mode)? then don't interrupt.
    [[ "${ALLOW_CREDITS:-off}" == "on" ]] && { _debug_log "credit-guard: crossing but ALLOW_CREDITS on"; return 0; }
    local cp cpi; cp=$(_credits_pct); cpi=${cp%.*}
    if [[ "${cpi:-0}" -ge 100 ]]; then
        _debug_log "credit-guard: session maxed, credits exhausted - nothing to block"
        _notify "resumer: session maxed and \$0 credits left - just wait for reset."
        return 0
    fi
    _credit_guard_interrupt
}

# ── status bar render ─────────────────────────────────────────────────

# $1 = optional SPILL warning text (e.g. "SPILL S91 C82") rendered in red.
_write_cache() {
    _load_config_fast
    local warn="${1:-}"
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
    # Credit-guard blocked count (agents paused to avoid paid spend).
    local cg
    cg=$(sql "SELECT COUNT(*) FROM limited WHERE status IN ('waiting','retrying') AND limit_type='credit-guard';" 2>/dev/null || echo 0)
    if [[ "${cg:-0}" -gt 0 ]]; then
        final="#[fg=white,bg=red,bold] CREDIT BLOCKED ${cg} #[default]${final:+ $final}"
    fi
    if [[ -n "$warn" ]]; then
        [[ -n "$final" ]] && final+=" "
        final+="$warn"   # already color-coded by _usage_warn (THROTTLE yellow / SPEND red)
    fi
    printf '%s' "$final" > "$CACHE.tmp" 2>/dev/null || true
    mv -f "$CACHE.tmp" "$CACHE" 2>/dev/null || true
    tmux set -gq @agent-resumer-status "$final" 2>/dev/null || true
}

# Badge warnings (accurate, no free/paid editorializing - session-max DOES spill
# into paid credits when extra-usage is on, confirmed empirically):
#   LIMIT   (yellow) = session/weekly plan window near full. At 100% Claude starts
#                      spending usage credits automatically.
#   CREDITS (red)    = paid usage-credit pool near its $ cap -> hard block next.
# Prints the pre-colored tmux segment(s), or nothing. #1 + #2.
_usage_warn() {
    python3 - "$1" "${WARN_SESSION:-90}" "${WARN_WEEKLY:-90}" "${WARN_CREDITS:-80}" <<'PY' 2>/dev/null || true
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
ws,ww,wc=float(sys.argv[2]),float(sys.argv[3]),float(sys.argv[4])
def util(o):
    try: return float((o or {}).get("utilization",0))
    except Exception: return 0.0
thr=[]
s=util(d.get("five_hour"))
if s>=ws: thr.append(f"S{int(round(s))}")
w=util(d.get("seven_day"))
if w>=ww: thr.append(f"W{int(round(w))}")
spend=[]
sp=d.get("spend") or {}
try: c=float(sp.get("percent",0))
except Exception: c=0.0
if sp.get("enabled") and c>=wc: spend.append(f"C{int(round(c))}")
seg=[]
# Background-block badges: high contrast on any status-bar colour.
if thr:   seg.append("#[fg=black,bg=yellow,bold] LIMIT "+" ".join(thr)+" #[default]")
if spend: seg.append("#[fg=white,bg=red,bold] CREDITS "+" ".join(spend)+" #[default]")
if seg: print(" ".join(seg))
PY
}

# Append session/weekly/credit numbers to a CSV, but only when a value changed -
# a delta log. Answers "when did credits move, and by how much" empirically. #2.
_usage_log() {
    local uf="$1" csv="$RESUMER_DIR/usage.csv" vals last
    [[ -f "$uf" ]] || return 0
    vals=$(python3 - "$uf" <<'PY' 2>/dev/null || true
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
def u(o):
    try: return round(float((o or {}).get("utilization",0)),1)
    except Exception: return 0.0
sp=d.get("spend") or {}
usd=(sp.get("used") or {})
_e=usd.get("exponent"); _e=2 if _e is None else int(_e)
used=usd.get("amount_minor",0)/10**_e
print(f"{u(d.get('five_hour'))},{u(d.get('seven_day'))},{sp.get('percent',0)},{used:.2f}")
PY
)
    [[ -z "$vals" ]] && return 0
    [[ -f "$csv" ]] || echo "epoch,iso,session_pct,weekly_pct,credits_pct,credits_used_usd" > "$csv"
    last=$(tail -1 "$csv" 2>/dev/null | cut -d, -f3-)
    [[ "$last" == "$vals" ]] && return 0   # unchanged -> skip (delta only)
    printf '%s,%s,%s\n' "$(date +%s)" "$(date '+%Y-%m-%dT%H:%M:%S')" "$vals" >> "$csv"
    _debug_log "usage.csv +row: $vals"
}

cmd_status_bar() { [[ -f "$CACHE" ]] && cat "$CACHE" || true; }

# Reconcile the limited table. THE self-healing heartbeat: scheduled sleep-timer
# retries die with the tmux server, so refresh (called every status-interval and
# on startup) drives resolution instead of relying on those timers.
#   1. prune rows whose pane is gone (agent closed) or empty -> nothing to resume.
#   2. run cmd_retry for rows that are due, plus all credit-guard rows (so they
#      resume promptly once the session resets, not only at the scheduled tick).
# Pruning runs even when disabled so stale entries/badge always clear.
cmd_sweep() {
    [[ -f "$DB" ]] || return 0
    local live now sid in_list
    live=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | paste -sd, - 2>/dev/null || true)
    now=$(date +%s)
    if [[ -n "$live" ]]; then
        in_list=$(printf "'%s'," ${live//,/ }); in_list="${in_list%,}"
        sql "DELETE FROM limited WHERE status IN ('waiting','retrying')
             AND (COALESCE(tmux_pane,'')='' OR tmux_pane NOT IN ($in_list));" 2>/dev/null || true
    else
        sql "DELETE FROM limited WHERE status IN ('waiting','retrying');" 2>/dev/null || true
    fi
    [[ "${ENABLED:-off}" == "on" ]] || return 0
    while IFS= read -r sid; do
        [[ -z "$sid" ]] && continue
        cmd_retry "$sid" 2>/dev/null || true
    done < <(sql "SELECT session_id FROM limited
                  WHERE status IN ('waiting','retrying')
                    AND (COALESCE(next_retry_at,0) <= $now OR limit_type='credit-guard');" 2>/dev/null)
}

cmd_refresh() {
    [[ -f "$DB" ]] || return 0
    _load_config_fast
    local warn="" uf
    if uf=$(cmd_usage_fetch 2>/dev/null); then warn=$(_usage_warn "$uf"); _usage_log "$uf"; fi
    # Throttled + locked: only ONE client's refresh does the work per interval
    # (many attached clients each call refresh on the same status-interval tick).
    local stamp="$RESUMER_DIR/.last_scan" now last=0
    now=$(date +%s)
    [[ -f "$stamp" ]] && last=$(_file_mtime "$stamp" 2>/dev/null || echo 0)
    if [[ $((now - last)) -ge "$SCAN_INTERVAL" ]] && _try_lock refresh; then
        touch "$stamp"
        cmd_sweep 2>/dev/null || true            # prune dead panes + run due retries (also when disabled)
        if [[ "${ENABLED:-off}" == "on" ]]; then
            cmd_scan 2>/dev/null || true
            cmd_credit_guard 2>/dev/null || true
            _caffeinate_sync 2>/dev/null || true
        fi
        _unlock refresh
    fi
    _write_cache "$warn" 2>/dev/null || true
}

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
    local raw tok status tmpf
    raw=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)
    if [[ -n "$raw" ]]; then
        tok=$(printf '%s' "$raw" | python3 -c 'import json,sys;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null || true)
        if [[ -n "$tok" ]]; then
            # Unique temp per fetch so concurrent writers never share a buffer.
            tmpf=$(mktemp "$USAGE_JSON.XXXXXX" 2>/dev/null || echo "$USAGE_JSON.tmp.$$")
            status=$(curl -sS -m 10 -o "$tmpf" -w '%{http_code}' \
                -H "Authorization: Bearer $tok" -H "Content-Type: application/json" \
                "$USAGE_URL" 2>/dev/null || echo 000)
            if [[ "$status" == "200" ]]; then
                mv -f "$tmpf" "$USAGE_JSON"
                _debug_log "usage fetched via endpoint (200)"
                printf '%s' "$USAGE_JSON"; return 0
            fi
            rm -f "$tmpf" 2>/dev/null || true
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
    _ue=u.get("exponent"); _ue=2 if _ue is None else int(_ue)
    _le=li.get("exponent"); _le=2 if _le is None else int(_le)
    ue=10**_ue; le=10**_le
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

    # Freshen the limited table so the list reflects current state: reconcile
    # (prune dead panes, run due retries) unconditionally, then scan for new limits.
    cmd_sweep 2>/dev/null || true
    [[ "${ENABLED:-off}" == "on" ]] && { cmd_scan 2>/dev/null || true; }

    local found=0 nowm sid type target next st proj eta rel d label
    nowm=$(date +%s)
    # char(31) delimiter: session/target names may contain '|'.
    while IFS=$'\x1f' read -r sid type target next st; do
        [[ -z "$sid" ]] && continue
        found=$((found+1))
        proj=""
        [[ -f "$TRACKER_DB" ]] && proj=$(sqlite3 "$TRACKER_DB" \
            "SELECT project_name FROM sessions WHERE session_id='$(sql_esc "$sid")' LIMIT 1;" 2>/dev/null || true)
        [[ -z "$proj" ]] && proj="${target:-$sid}"
        label="! ${proj} [${type}]"
        if [[ "${next:-0}" -gt 0 ]]; then
            eta=$(date -r "$next" '+%H:%M' 2>/dev/null || true)
            d=$(( next - nowm ))
            if   [[ "$d" -le 0 ]]; then rel="due now"
            elif [[ "$d" -lt 3600 ]]; then rel="in $((d/60))m"
            else rel="in $((d/3600))h$(( (d%3600)/60 ))m"; fi
            [[ -n "$eta" ]] && label="${label} resume ~${eta} (${rel})"
        fi
        [[ "$st" == "retrying" ]] && label="${label} [retrying]"
        label="${label//#/}"   # strip '#' so tmux does not format-expand the label
        if [[ -n "$target" ]]; then
            # Pass the session_id (UUID / %pane - no quotes/spaces), not the target,
            # so a session name with a quote/space/# can't break the command string.
            # cmd_goto resolves the target from the DB by session_id.
            args+=("$label" "" "run-shell '$SCRIPTS_DIR/resumer.sh goto $sid'")
        else
            args+=("$label (no pane)" "" "")
        fi
    done < <(sql "SELECT session_id||char(31)||limit_type||char(31)||COALESCE(tmux_target,'')||char(31)||COALESCE(next_retry_at,0)||char(31)||status
                  FROM limited WHERE status IN ('waiting','retrying') ORDER BY COALESCE(next_retry_at,0);" 2>/dev/null)
    [[ "$found" -eq 0 ]] && args+=("No paused agents" "" "")

    args+=("" "" "")
    args+=("Options >" "o" "run-shell '$SCRIPTS_DIR/resumer.sh options'")
    args+=("Refresh" "r" "run-shell '$SCRIPTS_DIR/resumer.sh menu'")
    args+=("Quit" "q" "")

    # Test seam: print the menu instead of popping it (no attached client needed).
    if [[ "${RESUMER_MENU_DRYRUN:-0}" == "1" ]]; then
        printf '%s\n' "${args[@]}"
        return 0
    fi
    tmux display-menu "${args[@]}"
}

# Flip a boolean tmux option on<->off and bust the config cache.
cmd_toggle() {
    local name="${1:?Usage: resumer.sh toggle <name>}" opt def cur
    case "$name" in
        enabled)       opt="@agent-resumer-enabled"; def="off" ;;
        caffeinate)    opt="@agent-resumer-caffeinate"; def="on" ;;
        allow-credits) opt="@agent-resumer-allow-credits"; def="off" ;;
        *) return 1 ;;
    esac
    cur=$(get_tmux_option "$opt" "$def")
    if [[ "$cur" == "on" ]]; then tmux set -g "$opt" "off"; else tmux set -g "$opt" "on"; fi
    rm -f "$RESUMER_DIR/config_cache" 2>/dev/null || true
    _debug_log "toggle $name -> $([[ "$cur" == on ]] && echo off || echo on)"
}

# Options submenu: checkbox toggles, reopens itself after each flip. Modeled on
# tmux-worktree's display-menu.
cmd_options() {
    local en caf ntfy allow
    en=$(get_tmux_option "@agent-resumer-enabled" "off")
    caf=$(get_tmux_option "@agent-resumer-caffeinate" "on")
    ntfy=$(get_tmux_option "@agent-resumer-ntfy-topic" "")
    allow=$(get_tmux_option "@agent-resumer-allow-credits" "off")
    box() { [[ "$1" == "on" ]] && printf '[x]' || printf '[ ]'; }
    local self="run-shell '$SCRIPTS_DIR/resumer.sh options'"
    local args=(-T "Resumer Options")
    # The safety toggle: OFF (default) = paid credits blocked at session-max.
    args+=("$(box "$allow") Allow usage credits (PAID)" "a" "run-shell '$SCRIPTS_DIR/resumer.sh toggle allow-credits' ; $self")
    args+=("$(box "$en") auto-resume"          "e" "run-shell '$SCRIPTS_DIR/resumer.sh toggle enabled' ; $self")
    args+=("$(box "$caf") caffeinate-while-paused" "c" "run-shell '$SCRIPTS_DIR/resumer.sh toggle caffeinate' ; $self")
    args+=("$(box "$([[ -n "$ntfy" ]] && echo on)") ntfy push: ${ntfy:-off}" "" "")
    args+=("" "" "")
    args+=("< Back to status"  "b" "run-shell '$SCRIPTS_DIR/resumer.sh menu'")
    args+=("Quit" "q" "")
    if [[ "${RESUMER_MENU_DRYRUN:-0}" == "1" ]]; then printf '%s\n' "${args[@]}"; return 0; fi
    tmux display-menu "${args[@]}"
}

# Jump to a pane. Arg is a session_id (resolved to its target via the DB) or,
# for back-compat, a literal 'session:window.pane' target.
cmd_goto() {
    local arg="${1:?Usage: resumer.sh goto <session_id|session:window.pane>}"
    local target=""
    [[ -f "$DB" ]] && target=$(sql "SELECT tmux_target FROM limited WHERE session_id='$(sql_esc "$arg")' LIMIT 1;" 2>/dev/null || true)
    [[ -z "$target" ]] && target="$arg"    # literal target fallback
    [[ -z "$target" ]] && return 0
    local sess="${target%%:*}" win="${target%.*}"
    tmux switch-client -t "$sess" 2>/dev/null || true
    tmux select-window -t "$win" 2>/dev/null || true
    tmux select-pane -t "$target" 2>/dev/null || true
    _debug_log "goto arg=$arg target=$target"
}

# Verify the core keystroke assumption against a REAL (non-limited) Claude pane:
# does Escape interrupt, and does the resume prompt land in the input box? Shows
# before/after pane captures. Non-destructive: types the prompt then clears it
# (C-u), never submits, unless --submit is passed.
cmd_selftest() {
    local pane="${1:?Usage: resumer.sh selftest <pane-id> [--submit]}" submit="${2:-}"
    _load_config_fast
    tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx "$pane" \
        || { echo "pane $pane not found (run 'tmux list-panes -a' to find your Claude pane)"; return 1; }
    local rp="${RESUME_PROMPT:-resume}" esc="${INTERRUPT_ESCAPES:-1}" i
    echo "=== pane $pane BEFORE (last 4 lines) ==="; tmux capture-pane -t "$pane" -p 2>/dev/null | grep . | tail -4
    echo "=== sending Escape x$esc (should interrupt a running turn) ==="
    i=0; while [[ "$i" -lt "$esc" ]]; do tmux send-keys -t "$pane" Escape 2>/dev/null || true; i=$((i+1)); done
    sleep 1
    tmux capture-pane -t "$pane" -p 2>/dev/null | grep . | tail -4
    echo "=== typing '$rp' into the input box (not submitted) ==="
    tmux send-keys -t "$pane" "$rp" 2>/dev/null || true
    sleep 1
    tmux capture-pane -t "$pane" -p 2>/dev/null | grep . | tail -4
    if [[ "$submit" == "--submit" ]]; then
        echo "=== submitting (Enter) ==="; tmux send-keys -t "$pane" Enter 2>/dev/null || true
    else
        echo "=== clearing input (C-u) - not submitted ==="; tmux send-keys -t "$pane" C-u 2>/dev/null || true
    fi
    echo "REVIEW: did Escape interrupt the turn, and did '$rp' appear in the input box?"
    echo "If not, adjust @agent-resumer-resume-prompt / @agent-resumer-interrupt-escapes."
}

# Health check: surface silent failure modes (missing deps, token, hooks, etc).
cmd_doctor() {
    _load_config_fast
    local pass=0 fail=0
    _ck() { if eval "$2" >/dev/null 2>&1; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
    echo "tmux-agent-resumer doctor"
    echo "- dependencies"
    _ck "sqlite3 present"  "command -v sqlite3"
    _ck "python3 present"  "command -v python3"
    _ck "curl present"     "command -v curl"
    _ck "security present" "command -v security"
    _ck "tmux 3.0+"        "check_tmux_version 3.0"
    echo "- usage data"
    _ck "keychain item readable"  "security find-generic-password -s '$KEYCHAIN_SERVICE' -w"
    local tok; tok=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null || true)
    _ck "oauth token parses"      "[ -n '$tok' ]"
    if [[ -n "$tok" ]]; then
        local code; code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" -H "Content-Type: application/json" "$USAGE_URL" 2>/dev/null || echo 000)
        _ck "usage endpoint 200 (got $code)" "[ '$code' = 200 ]"
    fi
    echo "- state / integration"
    _ck "resumer DB present"          "[ -f '$DB' ]"
    _ck "limited table"               "sqlite3 '$DB' \"SELECT 1 FROM sqlite_master WHERE name='limited'\" | grep -q 1"
    _ck "guard_state table"           "sqlite3 '$DB' \"SELECT 1 FROM sqlite_master WHERE name='guard_state'\" | grep -q 1"
    _ck "tracker DB present"          "[ -f '$TRACKER_DB' ]"
    _ck "Stop/StopFailure hooks set"  "grep -q tmux-agent-resumer '$HOME/.claude/settings.json'"
    _ck "status segment injected"     "tmux show-option -gqv status-right | grep -q '@agent-resumer-status'"
    echo "- config"
    echo "  enabled=$(get_tmux_option @agent-resumer-enabled off)  allow-credits=$(get_tmux_option @agent-resumer-allow-credits off)  caffeinate=$(get_tmux_option @agent-resumer-caffeinate on)  ntfy=$(get_tmux_option @agent-resumer-ntfy-topic '(off)')"
    echo "result: $pass ok, $fail fail"
    [[ "$fail" -eq 0 ]]
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
        scan)        cmd_scan ;;
        sweep)       cmd_sweep ;;
        credit-guard) cmd_credit_guard ;;
        options)     cmd_options ;;
        toggle)      cmd_toggle "${2:-}" ;;
        selftest)    cmd_selftest "${2:-}" "${3:-}" ;;
        doctor)      cmd_doctor ;;
        *) echo "Usage: resumer.sh {init|hook <event>|detect-file <path>|retry <sid>|status-bar|refresh|cleanup|menu|usage|goto <target>|scan|sweep|credit-guard|options|toggle <name>|selftest <pane> [--submit]|doctor}" >&2
           exit 1 ;;
    esac
fi
