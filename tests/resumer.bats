#!/usr/bin/env bats
# Unit tests for the safe (non-intrusive) parts of tmux-agent-resumer:
# limit classification, backoff math, and the detect-file analyzer.
# The resume/send-keys path is intentionally NOT tested here - it is held
# behind the reproduction gate and ships disabled.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/resumer.sh"
    TMPD="$(mktemp -d)"
    export RESUMER_DIR="$TMPD/state"
    export DB="$RESUMER_DIR/resumer.db"
    export CACHE="$RESUMER_DIR/status_cache"
    # source for pure-function access (dispatcher is guarded)
    source "$SCRIPT"

    SPEND_LINE='{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"You'"'"'ve hit your org'"'"'s monthly spend limit · run /usage-credits to ask your admin for a higher limit"}]},"isApiErrorMessage":true,"apiErrorStatus":429,"error":"rate_limit"}'
    USAGE_LINE='{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"You'"'"'ve hit your weekly limit · resets Jul 20, 3pm"}]},"isApiErrorMessage":true,"apiErrorStatus":429,"error":"rate_limit"}'
    SERVERERR_LINE='{"type":"assistant","message":{"content":[{"type":"text","text":"API Error: Unable to connect"}]},"isApiErrorMessage":true,"apiErrorStatus":500,"error":"server_error"}'
    NORMAL_LINE='{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}'

    mkdir -p "$TMPD"
    printf '%s\n%s\n' "$NORMAL_LINE" "$SPEND_LINE"  > "$TMPD/spend.jsonl"
    printf '%s\n%s\n' "$NORMAL_LINE" "$USAGE_LINE"  > "$TMPD/usage.jsonl"
    printf '%s\n%s\n' "$NORMAL_LINE" "$SERVERERR_LINE" > "$TMPD/server.jsonl"
    printf '%s\n%s\n' "$SPEND_LINE"  "$NORMAL_LINE"  > "$TMPD/recovered.jsonl"
    printf '%s\n' "$NORMAL_LINE" > "$TMPD/clean.jsonl"
}

teardown() {
    [[ -f "$RESUMER_DIR/caffeinate.pid" ]] && kill "$(cat "$RESUMER_DIR/caffeinate.pid" 2>/dev/null)" 2>/dev/null
    rm -rf "$TMPD"
}

@test "classify: spend cap message" {
    run _classify_limit "You've hit your org's monthly spend limit · run /usage-credits"
    [ "$output" = "spend" ]
}

@test "classify: weekly usage limit" {
    run _classify_limit "You've hit your weekly limit · resets Jul 20, 3pm"
    [ "$output" = "usage" ]
}

@test "classify: session (5h) limit" {
    run _classify_limit "You've hit your session limit"
    [ "$output" = "usage" ]
}

@test "classify: unknown text" {
    run _classify_limit "some unrelated assistant text"
    [ "$output" = "unknown" ]
}

@test "backoff doubles" {
    BACKOFF_CAP=3600
    run _next_backoff 120 usage
    [ "$output" = "240" ]
}

@test "backoff caps" {
    BACKOFF_CAP=3600
    run _next_backoff 3000 usage
    [ "$output" = "3600" ]
}

@test "detect-file: spend transcript" {
    run bash "$SCRIPT" detect-file "$TMPD/spend.jsonl"
    [[ "$output" == spend$'\t'* ]]
}

@test "detect-file: usage transcript" {
    run bash "$SCRIPT" detect-file "$TMPD/usage.jsonl"
    [[ "$output" == usage$'\t'* ]]
}

@test "detect-file: 500 server error is NOT a limit" {
    run bash "$SCRIPT" detect-file "$TMPD/server.jsonl"
    [ "$output" = "NONE" ]
}

@test "detect-file: recovered session (last record clean) is NONE" {
    run bash "$SCRIPT" detect-file "$TMPD/recovered.jsonl"
    [ "$output" = "NONE" ]
}

@test "detect-file: clean transcript is NONE" {
    run bash "$SCRIPT" detect-file "$TMPD/clean.jsonl"
    [ "$output" = "NONE" ]
}

@test "init creates limited table" {
    run bash "$SCRIPT" init
    [ "$status" -eq 0 ]
    run sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='limited';"
    [ "$output" = "limited" ]
}

@test "warn badge: LIMIT (session/weekly) and CREDITS split correctly" {
    WARN_SESSION=90 WARN_WEEKLY=90 WARN_CREDITS=80
    printf '%s' '{"five_hour":{"utilization":93},"seven_day":{"utilization":40},"spend":{"enabled":true,"percent":85}}' > "$TMPD/hot.json"
    run _usage_warn "$TMPD/hot.json"
    [[ "$output" == *"LIMIT"* ]]         # session over -> plan-limit segment
    [[ "$output" == *"S93"* ]]
    [[ "$output" == *"CREDITS"* ]]       # credits over -> credit segment
    [[ "$output" == *"C85"* ]]
    [[ "$output" != *"W40"* ]]           # weekly 40% under threshold
}

@test "warn badge: silent below thresholds (your live numbers)" {
    WARN_SESSION=90 WARN_WEEKLY=90 WARN_CREDITS=80
    printf '%s' '{"five_hour":{"utilization":33},"seven_day":{"utilization":19},"spend":{"enabled":true,"percent":15}}' > "$TMPD/cool.json"
    run _usage_warn "$TMPD/cool.json"
    [ -z "$output" ]
}

@test "spill warn: credits ignored when overage disabled" {
    WARN_CREDITS=80
    printf '%s' '{"spend":{"enabled":false,"percent":99}}' > "$TMPD/nocredit.json"
    run _usage_warn "$TMPD/nocredit.json"
    [ -z "$output" ]
}

@test "caffeinate: off -> never spawns" {
    bash "$SCRIPT" init >/dev/null
    ENABLED=on CAFFEINATE=off
    sqlite3 "$DB" "INSERT INTO limited (session_id,limit_type,transcript_path,status) VALUES ('s','usage','/tmp/x','waiting');"
    _caffeinate_sync
    [ ! -f "$RESUMER_DIR/caffeinate.pid" ]
}

@test "caffeinate: on -> holds while paused, releases when clear" {
    bash "$SCRIPT" init >/dev/null
    ENABLED=on CAFFEINATE=on
    sqlite3 "$DB" "INSERT INTO limited (session_id,limit_type,transcript_path,status) VALUES ('s','usage','/tmp/x','waiting');"
    _caffeinate_sync
    [ -f "$RESUMER_DIR/caffeinate.pid" ]
    local p; p=$(cat "$RESUMER_DIR/caffeinate.pid")
    kill -0 "$p"                                   # alive while paused
    sqlite3 "$DB" "UPDATE limited SET status='resumed';"
    _caffeinate_sync
    [ ! -f "$RESUMER_DIR/caffeinate.pid" ]          # released
    run kill -0 "$p"; [ "$status" -ne 0 ]           # process gone
}

@test "integration: retry sends resume while limited, then resumed when cleared" {
    bash "$SCRIPT" init >/dev/null
    ENABLED=on CAFFEINATE=off NTFY_TOPIC=""
    SENT="$TMPD/sent"; : > "$SENT"
    # test doubles: fake a live, non-viewed pane with a live agent
    tmux() {
        local a="$*"
        case "$a" in
            "list-panes -a -F #{pane_id}") echo "%9" ;;
            *"-p #{pane_pid}"*) echo 4242 ;;
            *pane_active*) echo 0 ;;                 # not being viewed
            *"send-keys"*) printf '%s\n' "$a" >> "$SENT" ;;
            *) : ;;                                  # swallow run-shell etc.
        esac
    }
    _has_agent_child() { return 0; }
    local TP="$TMPD/it.jsonl"
    printf '%s\n' "$SPEND_LINE" > "$TP"              # transcript ends in a 429
    sqlite3 "$DB" "INSERT INTO limited (session_id,tmux_pane,tmux_target,limit_type,transcript_path,resume_prompt,retry_count,backoff_secs,next_retry_at,status) VALUES ('it','%9','s:1.9','usage','$TP','resume',0,120,$(date +%s),'waiting');"

    cmd_retry it                                     # still limited -> should send resume
    grep -q "send-keys -t %9 resume Enter" "$SENT"
    run sqlite3 "$DB" "SELECT status||':'||retry_count FROM limited WHERE session_id='it';"
    [ "$output" = "retrying:1" ]

    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}' > "$TP"
    cmd_retry it                                     # cleared -> resumed
    run sqlite3 "$DB" "SELECT status FROM limited WHERE session_id='it';"
    [ "$output" = "resumed" ]
}

@test "integration: retry gives up when pane is gone" {
    bash "$SCRIPT" init >/dev/null
    ENABLED=on
    tmux() { case "$*" in "list-panes -a -F #{pane_id}") echo "%1" ;; *) : ;; esac; }  # %9 not listed
    sqlite3 "$DB" "INSERT INTO limited (session_id,tmux_pane,limit_type,transcript_path,status) VALUES ('g','%9','usage','/tmp/x','waiting');"
    cmd_retry g
    run sqlite3 "$DB" "SELECT status FROM limited WHERE session_id='g';"
    [ "$output" = "gaveup" ]
}

@test "retry no-ops (no typing) when disabled" {
    bash "$SCRIPT" init >/dev/null
    sqlite3 "$DB" "INSERT INTO limited (session_id,tmux_pane,limit_type,transcript_path,status) VALUES ('s','%1','usage','/tmp/x','waiting');"
    ENABLED=off
    run cmd_retry s
    [ "$status" -eq 0 ]
    # row untouched (still waiting, retry_count 0) since disabled
    run sqlite3 "$DB" "SELECT status||':'||retry_count FROM limited WHERE session_id='s';"
    [ "$output" = "waiting:0" ]
}
