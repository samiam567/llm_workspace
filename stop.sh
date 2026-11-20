
#!/usr/bin/env bash

# ============================================
# Stop All OpenTerminal Sessions
# WSL2 / Native Ubuntu
# ============================================

set -uo pipefail

PREFIX="openterminal-"

echo "=========================================="
echo "    Stopping OpenTerminal Sessions"
echo "=========================================="
echo

if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is not installed."
    exit 1
fi

if ! tmux list-sessions >/dev/null 2>&1; then
    echo "No active tmux sessions found."
    exit 0
fi

sessions=$(tmux list-sessions -F '#{session_name}' |
    grep "^${PREFIX}" || true)

if [[ -z "$sessions" ]]; then
    echo "No OpenTerminal sessions are running."
    exit 0
fi

while IFS= read -r session; do
    [[ -z "$session" ]] && continue

    echo "Stopping: $session"

    if tmux kill-session -t "=$session"; then
        echo "Stopped: $session"
    else
        echo "WARNING: Could not stop $session"
    fi

done <<< "$sessions"

docker compose down

echo
echo "=========================================="
echo "All OpenTerminal sessions stopped."
echo "Sandboxes and Docker containers preserved."
echo "=========================================="
