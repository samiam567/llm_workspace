#!/usr/bin/env bash

# ============================================
# Stop All OpenTerminal & GUI Sessions
# WSL2 / Native Ubuntu
# ============================================

set -uo pipefail

PREFIXES=("openterminal-" "gui-")

echo "=========================================="
echo "    Stopping OpenTerminal & GUI Sessions"
echo "=========================================="
echo

if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is not installed." >&2
    exit 1
fi

if ! tmux list-sessions >/dev/null 2>&1; then
    echo "No active tmux sessions found."
    exit 0
fi

all_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

matching_sessions=""
for prefix in "${PREFIXES[@]}"; do
    found=$(printf '%s\n' "$all_sessions" | grep "^${prefix}" || true)
    if [[ -n "$found" ]]; then
        matching_sessions="${matching_sessions}${found}"$'\n'
    fi
done

matching_sessions=$(printf '%s' "$matching_sessions" | sed '/^$/d' | sort -u || true)

if [[ -z "$matching_sessions" ]]; then
    echo "No OpenTerminal or GUI sessions are running."
    exit 0
fi

while IFS= read -r session; do
    [[ -z "$session" ]] && continue

    echo "Stopping: $session"

    if tmux kill-session -t "=$session"; then
        echo "Stopped: $session"
    else
        echo "WARNING: Could not stop $session" >&2
    fi

done <<< "$matching_sessions"

echo
echo "=========================================="
echo "All OpenTerminal and GUI sessions stopped."
echo "Sandboxes and Docker containers preserved."
echo "=========================================="