```bash
#!/usr/bin/env bash

# ============================================
# Multi-Sandbox OpenTerminal Manager
# ============================================

set -uo pipefail

# --------------------------------------------
# Configuration paths
# --------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/sandboxes.json"

# --------------------------------------------
# Load and validate configuration
# --------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: sandboxes.json not found." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required. Install it with: sudo apt install jq" >&2
    exit 1
fi

if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo "ERROR: Invalid JSON configuration." >&2
    exit 1
fi

sandbox_count=$(jq '.sandboxes // [] | length' "$CONFIG_FILE")

if [[ "$sandbox_count" -eq 0 ]]; then
    echo "No sandboxes configured."
    exit 0
fi

mapfile -t enabled < <(
    jq -c '.sandboxes[] | select(.enabled == true)' "$CONFIG_FILE"
)

if [[ ${#enabled[@]} -eq 0 ]]; then
    echo "No enabled sandboxes."
    exit 0
fi

# --------------------------------------------
# Validate unique names and ports
# --------------------------------------------

duplicate_names=$(jq -r '
    [.sandboxes[] | select(.enabled == true) | ."sandbox-name"]
    | group_by(.)
    | map(select(length > 1) | .[0])
    | .[]
' "$CONFIG_FILE")

duplicate_ports=$(jq -r '
    [.sandboxes[] | select(.enabled == true) | ."sandbox-port"]
    | group_by(.)
    | map(select(length > 1) | .[0])
    | .[]
' "$CONFIG_FILE")

if [[ -n "$duplicate_names" ]]; then
    echo "ERROR: Duplicate sandbox names detected: $duplicate_names"
    exit 1
fi

if [[ -n "$duplicate_ports" ]]; then
    echo "ERROR: Duplicate OpenTerminal ports detected: $duplicate_ports"
    exit 1
fi

# --------------------------------------------
# Start Docker Compose
# --------------------------------------------

echo
echo "Starting Docker Compose..."

if ! (cd "$SCRIPT_DIR" && docker compose up -d); then
    echo "ERROR: Docker Compose failed to start."
    exit 1
fi

# --------------------------------------------
# Process each sandbox
# --------------------------------------------

for sandbox in "${enabled[@]}"; do

    name=$(jq -r '."sandbox-name" // empty' <<< "$sandbox")
    workspace=$(jq -r '."sandbox-workspace-folder" // empty' <<< "$sandbox")
    api_key=$(jq -r '."sandbox-api-key" // empty' <<< "$sandbox")
    port=$(jq -r '."sandbox-port" // empty' <<< "$sandbox")

    echo
    echo "========================================"
    echo "Processing sandbox: $name"
    echo "Workspace: $workspace"
    echo "OpenTerminal port: $port"
    echo "========================================"

    # ----------------------------------------
    # Validate required settings
    # ----------------------------------------

    if [[ -z "$name" || -z "$workspace" || -z "$api_key" ||
          "$api_key" == YOUR_SECRET* ]]; then

        echo "Invalid configuration for $name. Skipping."
        continue
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]] ||
       (( port < 1 || port > 65535 )); then
        echo "Invalid port for $name. Skipping."
        continue
    fi

    # ----------------------------------------
    # Resolve workspace path
    # ----------------------------------------

    if [[ "$workspace" != /* ]]; then
        workspace="$SCRIPT_DIR/$workspace"
    fi

    # Create workspace if missing
    if [[ ! -d "$workspace" ]]; then
        mkdir -p "$workspace"
        echo "Created workspace: $workspace"
    fi

    # ----------------------------------------
    # Check whether sandbox exists
    # ----------------------------------------

    if ! sandbox_list=$(sbx list 2>&1); then
        echo "Unable to retrieve sandbox list."
        echo "$sandbox_list"
        continue
    fi

    exists=false

    if awk -v n="$name" '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == n) found = 1
            }
        }
        END { exit !found }
    ' <<< "$sandbox_list"; then
        exists=true
    fi

    # ----------------------------------------
    # Create sandbox if necessary
    # ----------------------------------------

    if [[ "$exists" == false ]]; then

        echo "Creating sandbox $name..."

        # Optional disk configuration
        root_size=$(jq -r '."sandbox-root-size" // empty' <<< "$sandbox")
        docker_size=$(jq -r '."sandbox-docker-size" // empty' <<< "$sandbox")

        # Build environment arguments
        env_args=()

        if [[ -n "$root_size" ]]; then
            echo "Root filesystem size: $root_size"
            env_args+=("DOCKER_SANDBOXES_ROOT_SIZE=$root_size")
        fi

        if [[ -n "$docker_size" ]]; then
            echo "Docker storage size: $docker_size"
            env_args+=("DOCKER_SANDBOXES_DOCKER_SIZE=$docker_size")
        fi

        # Create sandbox
        if ! env "${env_args[@]}" sbx create \
            --name "$name" shell "$workspace"; then

            echo "Sandbox creation failed."
            continue
        fi

        # Publish ports
        if ! sbx ports "$name" --publish "0.0.0.0:$port:8000"; then
            echo "Port configuration failed."
            continue
        fi

        echo "Installing OpenTerminal..."

        if ! sbx exec "$name" bash -c \
            "python3 -m pip install --upgrade open-terminal --break-system-packages"; then

            echo "OpenTerminal installation failed."
            continue
        fi

        echo "Sandbox created successfully."

    else

        echo "Sandbox '$name' already exists."
        echo "It will be started automatically by sbx run."
        echo "Existing port mappings are left unchanged."

    fi

    # ----------------------------------------
    # Encode API key
    # ----------------------------------------

    encoded_key=$(printf '%s' "$api_key" | base64 | tr -d '\n')

    # ----------------------------------------
    # Construct OpenTerminal launch command
    # ----------------------------------------

    terminal_command="KEY=\$(printf '%s' '$encoded_key' | base64 -d); exec open-terminal run --host 0.0.0.0 --port 8000 --api-key \"\$KEY\""

    # ----------------------------------------
    # Launch OpenTerminal in separate window
    # ----------------------------------------

    echo "Launching OpenTerminal for $name on port $port..."

    if command -v x-terminal-emulator >/dev/null 2>&1; then

        sbx_command=(sbx run --name "$name" -- -c "$terminal_command")

        x-terminal-emulator -e "${sbx_command[@]}" &

    else

        echo "WARNING: No graphical terminal emulator found."
        echo "Launching in background instead."

        log_file="$SCRIPT_DIR/${name}.log"

        sbx run --name "$name" -- -c "$terminal_command" \
            > "$log_file" 2>&1 &

        echo "Log file: $log_file"

    fi

done

# --------------------------------------------
# Finished
# --------------------------------------------

echo
echo "========================================"
echo "Sandbox manager finished."
echo "Enabled sandboxes: ${#enabled[@]}"
echo "========================================"
```