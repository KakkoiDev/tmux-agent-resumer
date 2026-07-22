#!/usr/bin/env bash
set -euo pipefail

# uninstall.sh - remove tmux-agent-resumer hooks + CLI symlink. Leaves the DB.

SETTINGS="$HOME/.claude/settings.json"
command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "$SETTINGS.resumer.bak.$(date +%s)"
    tmp="$(mktemp)"
    jq '
        if .hooks then
            .hooks |= with_entries(
                .value |= map(
                    .hooks |= map(select(.command | startswith("tmux-agent-resumer") | not))
                ) | map(select((.hooks | length) > 0))
            ) | .hooks |= with_entries(select((.value | length) > 0))
        else . end
    ' "$SETTINGS" > "$tmp"
    # Write THROUGH the symlink to preserve a symlinked settings.json.
    cat "$tmp" > "$SETTINGS" && rm -f "$tmp"
    echo "removed resumer hooks from $SETTINGS"
fi

rm -f "$HOME/.local/bin/tmux-agent-resumer"
echo "removed CLI symlink."

# Disarm: clear the enable option, kill any held caffeinate, drop pending rows
# so no scheduled retry timer types into a pane after uninstall.
RD="${RESUMER_DIR:-$HOME/.tmux-agent-resumer}"
tmux set -gu @agent-resumer-enabled 2>/dev/null || true
tmux set -g  @agent-resumer-status "" 2>/dev/null || true
if [[ -f "$RD/caffeinate.pid" ]]; then
    kill "$(cat "$RD/caffeinate.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "$RD/caffeinate.pid"
fi
if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$RD/resumer.db" ]]; then
    sqlite3 "$RD/resumer.db" "DELETE FROM limited WHERE status IN ('waiting','retrying');" 2>/dev/null || true
fi
rm -f "$RD/config_cache" 2>/dev/null || true
echo "disarmed (enabled option cleared, caffeinate killed, pending rows dropped)."
echo "DB left at $RD (rm -rf it to fully remove). Remove the run-shell line from ~/.tmux.conf too."
