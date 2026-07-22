#!/usr/bin/env bash
# TPM entry point for tmux-agent-resumer.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AGENT_RESUMER_PLUGIN_DIR="$CURRENT_DIR"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

source "$SCRIPTS_DIR/helpers.sh"
ensure_tmux_version || exit 1
load_config

"$SCRIPTS_DIR/resumer.sh" init >/dev/null 2>&1
# Reconcile after a (re)start: scheduled retry timers died with the previous tmux
# server, so prune rows for panes that no longer exist and resolve any due ones.
rm -f "${RESUMER_DIR:-$HOME/.tmux-agent-resumer}/.last_scan" 2>/dev/null || true
"$SCRIPTS_DIR/resumer.sh" sweep >/dev/null 2>&1 || true

_link_if_stale() {
    local target="$1" link="$2"
    [[ "$(readlink "$link" 2>/dev/null)" == "$target" ]] && return
    mkdir -p "$(dirname "$link")"
    ln -sf "$target" "$link"
}
_link_if_stale "$CURRENT_DIR/bin/tmux-agent-resumer" "$HOME/.local/bin/tmux-agent-resumer"

# <prefix>+R : usage + paused-agents modal. Single-quote the path so a plugin dir
# containing spaces survives the /bin/sh word-split inside run-shell.
RESUMER_KEY=$(get_tmux_option "@agent-resumer-key" "R")
tmux bind-key "$RESUMER_KEY" run-shell "'$SCRIPTS_DIR/resumer.sh' menu"

tmux set -gq @agent-resumer-status ""

# Inject the status segment. The periodic ENGINE is the #(...refresh) runner, so
# key the decision on the runner specifically - not on the badge option - so we
# re-inject if a status-right rewrite dropped the runner but left the badge.
# Quote the path for spaces.
runner="#('$SCRIPTS_DIR/resumer.sh' refresh)"
current_status_right=$(tmux show-option -gqv status-right)
if [[ "$current_status_right" != *"resumer.sh' refresh"* && "$current_status_right" != *"resumer.sh refresh"* ]]; then
    tmux set -g status-right "#{@agent-resumer-status}${runner} ${current_status_right}"
fi
