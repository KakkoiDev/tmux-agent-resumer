#!/usr/bin/env bash
# TPM entry point for tmux-agent-resumer.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AGENT_RESUMER_PLUGIN_DIR="$CURRENT_DIR"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

source "$SCRIPTS_DIR/helpers.sh"
ensure_tmux_version || exit 1
load_config

"$SCRIPTS_DIR/resumer.sh" init >/dev/null 2>&1

_link_if_stale() {
    local target="$1" link="$2"
    [[ "$(readlink "$link" 2>/dev/null)" == "$target" ]] && return
    mkdir -p "$(dirname "$link")"
    ln -sf "$target" "$link"
}
_link_if_stale "$CURRENT_DIR/bin/tmux-agent-resumer" "$HOME/.local/bin/tmux-agent-resumer"

# <prefix>+R : usage + paused-agents modal
RESUMER_KEY=$(get_tmux_option "@agent-resumer-key" "R")
tmux bind-key "$RESUMER_KEY" run-shell "$SCRIPTS_DIR/resumer.sh menu"

tmux set -gq @agent-resumer-status ""

# Inject status segment if not already present. Coexists with the tracker's
# segment (distinct @agent-resumer-status option).
current_status_right=$(tmux show-option -gqv status-right)
if [[ "$current_status_right" != *"@agent-resumer-status"* && "$current_status_right" != *"resumer.sh"* ]]; then
    status_cmd="#{@agent-resumer-status}#($SCRIPTS_DIR/resumer.sh refresh)"
    tmux set -g status-right "${status_cmd} ${current_status_right}"
fi
