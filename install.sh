#!/usr/bin/env bash
set -euo pipefail

# install.sh - tmux-agent-resumer installer.
# NOTE: this modifies ~/.claude/settings.json (registers hooks). Review before running.
# The resume path stays disabled (@agent-resumer-enabled off) until you opt in.

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
# Observational until the reproduction gate is cleared. StopFailure is the most
# likely event fired when a turn dies on a 429; Stop is registered as a fallback.
RESUMER_EVENTS=(Stop StopFailure)

command -v jq >/dev/null 2>&1 || { echo "jq is required for install" >&2; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { echo "sqlite3 is required" >&2; exit 1; }

echo "==> init DB"
"$PLUGIN_DIR/scripts/resumer.sh" init

echo "==> symlink CLI -> ~/.local/bin/tmux-agent-resumer"
mkdir -p "$HOME/.local/bin"
ln -sf "$PLUGIN_DIR/bin/tmux-agent-resumer" "$HOME/.local/bin/tmux-agent-resumer"

echo "==> register hooks in $SETTINGS"
mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.resumer.bak.$(date +%s)"

tmp="$(mktemp)"; cp "$SETTINGS" "$tmp"
for event in "${RESUMER_EVENTS[@]}"; do
    cmd="tmux-agent-resumer hook $event"
    if jq -e --arg event "$event" --arg cmd "$cmd" \
        '.hooks[$event] // [] | map(.hooks[]? | select(.command == $cmd)) | length > 0' \
        "$tmp" >/dev/null 2>&1; then
        echo "    - $event already registered"; continue
    fi
    jq --arg event "$event" --arg cmd "$cmd" '
        .hooks[$event] = (.hooks[$event] // []) + [{
            matcher: "", hooks: [{type: "command", command: $cmd}]
        }]' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    echo "    + $event"
done
# Write THROUGH the symlink so a symlinked settings.json (e.g. a profile) stays a symlink.
cat "$tmp" > "$SETTINGS" && rm -f "$tmp"

echo "==> bind <prefix>+R -> usage & paused-agents modal"
RESUMER_KEY="$(tmux show-option -gqv @agent-resumer-key 2>/dev/null || true)"; RESUMER_KEY="${RESUMER_KEY:-R}"
if tmux info >/dev/null 2>&1; then
    tmux bind-key "$RESUMER_KEY" run-shell "$PLUGIN_DIR/scripts/resumer.sh menu"
    echo "    bound live (this tmux server)"
else
    echo "    no tmux server running - bind persists via agent-resumer.tmux"
fi

cat <<EOF

==> done
Try it now:  <prefix>+${RESUMER_KEY}   (usage %, resets, credits + any paused agents)
Status bar shows a red SPILL badge when a window nears the paid-overage threshold.

Persist across tmux restarts - add to ~/.tmux.conf:
  run-shell $PLUGIN_DIR/agent-resumer.tmux
Optional status-bar badge: add  #{@agent-resumer-status}  to status-right.

Auto-resume is OFF by default (nothing types into a pane yet). Before enabling:
  1. On the next real limit hit, check ~/.tmux-agent-resumer/debug.log for
     "DETECTED 429" (proves the hook fires) and note the pane state.
  2. Confirm 'resume'+Enter continues the post-429 TUI (else set
     @agent-resumer-resume-prompt). Then:  tmux set -g @agent-resumer-enabled on
EOF
