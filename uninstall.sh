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
echo "removed CLI symlink. DB left at ${RESUMER_DIR:-$HOME/.tmux-agent-resumer} (rm manually if wanted)."
