
#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

cd "$SCRIPT_DIR" || exit 1

echo "=========================================="
echo "    OpenTerminal Multi-Sandbox Manager"
echo "=========================================="
echo

if [[ ! -f "$SCRIPT_DIR/run-sandboxes.sh" ]]; then
    echo "ERROR: run-sandboxes.sh not found!"
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/sandboxes.json" ]]; then
    echo "ERROR: sandboxes.json not found!"
    exit 1
fi

exec bash "$SCRIPT_DIR/run-sandboxes.sh"
