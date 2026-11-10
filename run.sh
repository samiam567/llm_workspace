
#!/usr/bin/env bash

# OpenTerminal Multi-Sandbox Manager

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "    OpenTerminal Multi-Sandbox Manager"
echo "=========================================="
echo

# Check configuration
if [[ ! -f "$SCRIPT_DIR/sandboxes.json" ]]; then
    echo "ERROR: sandboxes.json not found!"
    read -r -p "Press Enter to exit..."
    exit 1
fi

# Check Linux manager
if [[ ! -f "$SCRIPT_DIR/run-sandboxes.sh" ]]; then
    echo "ERROR: run-sandboxes.sh not found!"
    read -r -p "Press Enter to exit..."
    exit 1
fi

# Make manager executable if necessary
chmod +x "$SCRIPT_DIR/run-sandboxes.sh"

# Launch manager
"$SCRIPT_DIR/run-sandboxes.sh"
EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
    echo
    echo "ERROR: Sandbox manager encountered an error."
else
    echo
    echo "All enabled sandboxes processed successfully."
fi

echo
read -r -p "Press Enter to exit..."

docker compose down

exit $EXIT_CODE
