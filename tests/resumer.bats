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

teardown() { rm -rf "$TMPD"; }

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
