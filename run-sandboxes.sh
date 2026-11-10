
#!/usr/bin/env bash

# ============================================
# Multi-Sandbox OpenTerminal Manager
# ============================================

set -Eeuo pipefail

# --------------------------------------------
# Configuration paths
# --------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/sandboxes.json"
LOG_DIR="$SCRIPT_DIR/logs"

# --------------------------------------------
# Helpers
# --------------------------------------------

info() {
    echo -e "\033[36m$1\033[0m"
}

success() {
    echo -e "\033[32m$1\033[0m"
}

warning() {
    echo -e "\033[33m$1\033[0m"
}

error() {
    echo -e "\033[31m$1\033[0m" >&2
}

die() {
    error "ERROR: $1"
    exit 1
}

# --------------------------------------------
# Check dependencies
# --------------------------------------------

for command in docker sbx jq; do
    command -v "$command" >/dev/null 2>&1 ||
        die "Required command '$command' was not found."
done

# --------------------------------------------
# Load and validate configuration
# --------------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
    die "sandboxes.json not found."
fi

if ! jq empty "$CONFIG_FILE" >/dev/null 2>&1; then
    die "sandboxes.json contains invalid JSON."
fi

sandbox_count=$(jq '.sandboxes | length' "$CONFIG_FILE")

if [[ "$sandbox_count" -eq 0 ]]; then
    warning "No sandboxes configured."
    exit 0
fi

# Only process enabled sandboxes.
enabled_count=$(jq '[.sandboxes[] | select(.enabled == true)] | length' "$CONFIG_FILE")

if [[ "$enabled_count" -eq 0 ]]; then
    warning "No enabled sandboxes configured."
    exit 0
fi

# Validate unique sandbox names.
duplicate_names=$(jq -r '
    [.sandboxes[] | select(.enabled == true) | .["sandbox-name"]]
    | group_by(.)
    | map(select(length > 1) | .[0])
    | .[]
' "$CONFIG_FILE")

if [[ -n "$duplicate_names" ]]; then
    die "Duplicate sandbox names detected: $duplicate_names"
fi

# Validate unique OpenTerminal ports.
duplicate_ports=$(jq -r '
    [.sandboxes[] | select(.enabled == true) | .["sandbox-port"]]
    | group_by(.)
    | map(select(length > 1) | .[0])
    | .[]
' "$CONFIG_FILE")

if [[ -n "$duplicate_ports" ]]; then
    die "Duplicate OpenTerminal ports detected: $duplicate_ports"
fi

# Validate port numbers.
while IFS= read -r port; do
    if ! [[ "$port" =~ ^[0-9]+$ ]] ||
       (( port < 1 || port > 65535 )); then
        die "Invalid OpenTerminal port: $port"
    fi
done < <(jq -r '.sandboxes[] | select(.enabled == true) | .["sandbox-port"]' "$CONFIG_FILE")

# --------------------------------------------
# Start Docker Compose
# --------------------------------------------

info "\nStarting Docker Compose..."

if ! docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d; then
    die "Docker Compose failed to start."
fi

# --------------------------------------------
# Prepare log directory
# --------------------------------------------

mkdir -p "$LOG_DIR"

# --------------------------------------------
# Detect terminal emulator
# --------------------------------------------

TERMINAL=""

for candidate in \
    x-terminal-emulator \
    gnome-terminal \
    konsole \
    xfce4-terminal \
    mate-terminal \
    lxterminal \
    xterm
do
    if command -v "$candidate" >/dev/null 2>&1; then
        TERMINAL="$candidate"
        break
    fi
done

if [[ -z "$TERMINAL" ]]; then
    warning "No terminal emulator detected. OpenTerminal instances will run in the background."
fi

# --------------------------------------------
# Process each enabled sandbox
# --------------------------------------------

while IFS= read -r sandbox; do

    name=$(jq -r '.["sandbox-name"] // empty' <<< "$sandbox")
    workspace=$(jq -r '.["sandbox-workspace-folder"] // empty' <<< "$sandbox")
    api_key=$(jq -r '.["sandbox-api-key"] // empty' <<< "$sandbox")
    port=$(jq -r '.["sandbox-port"] // empty' <<< "$sandbox")

    echo
    echo "========================================"
    info "Processing sandbox: $name"
    echo "Workspace: $workspace"
    echo "OpenTerminal port: $port"
    echo "========================================"

    # ----------------------------------------
    # Validate required settings
    # ----------------------------------------

    if [[ -z "$name" ||
          -z "$workspace" ||
          -z "$api_key" ||
          "$api_key" == YOUR_SECRET* ]]; then

        error "Invalid configuration for $name. Skipping."
        continue
    fi

    # ----------------------------------------
    # Resolve workspace relative to script
    # directory
    # ----------------------------------------

    if [[ "$workspace" != /* ]]; then
        workspace="$SCRIPT_DIR/$workspace"
    fi

    # Normalize path.
    workspace="$(realpath -m "$workspace")"

    # ----------------------------------------
    # Create workspace if missing
    # ----------------------------------------

    if [[ ! -d "$workspace" ]]; then
        mkdir -p "$workspace"
        success "Created workspace: $workspace"
    fi

    # ----------------------------------------
    # Check whether sandbox exists
    # ----------------------------------------

    if ! sandbox_list=$(sbx list 2>&1); then
        error "Unable to retrieve sandbox list."
        continue
    fi

    exists=false

    if grep -F -w -- "$name" <<< "$sandbox_list" >/dev/null; then
        exists=true
    fi

    # ----------------------------------------
    # Create sandbox if necessary
    # ----------------------------------------

    if [[ "$exists" == false ]]; then

        warning "Creating sandbox $name..."

        if ! sbx create --name "$name" shell "$workspace"; then
            error "Sandbox creation failed."
            continue
        fi

        # Publish OpenTerminal port.
        if ! sbx ports "$name" --publish "0.0.0.0:${port}:8000"; then
            error "Port configuration failed."
            continue
        fi

        warning "Installing OpenTerminal..."

        if ! sbx exec "$name" bash -c \
            "python3 -m pip install --upgrade open-terminal --break-system-packages"; then
            error "OpenTerminal installation failed."
            continue
        fi

        success "Sandbox created successfully."

    else

        success "Sandbox '$name' already exists."
        info "It will be started automatically by sbx run."
        warning "Existing port mappings are left unchanged."

    fi

    # ----------------------------------------
    # Encode API key for safe shell transport
    # ----------------------------------------

    encoded_key=$(printf '%s' "$api_key" | base64 | tr -d '\n')

    # ----------------------------------------
    # Construct OpenTerminal launch command
    # ----------------------------------------

    terminal_command="KEY=\$(printf '%s' '${encoded_key}' | base64 -d); exec open-terminal run --host 0.0.0.0 --port 8000 --api-key \"\$KEY\""

    # ----------------------------------------
    # Launch OpenTerminal
    # ----------------------------------------

    success "Launching OpenTerminal for $name on port $port..."

    log_file="$LOG_DIR/${name}.log"

    if [[ -n "$TERMINAL" ]]; then

        case "$TERMINAL" in

            gnome-terminal)
                gnome-terminal -- bash -lc \
                    "sbx run --name '$name' -- -c \"$terminal_command\"; echo; read -rp 'Press Enter to close...'"
                ;;

            konsole)
                konsole -e bash -lc \
                    "sbx run --name '$name' -- -c \"$terminal_command\"; echo; read -rp 'Press Enter to close...'"
                ;;

            xfce4-terminal)
                xfce4-terminal --command="bash -lc \"sbx run --name '$name' -- -c \\\"$terminal_command\\\"; exec bash\""
                ;;

            mate-terminal)
                mate-terminal -- bash -lc \
                    "sbx run --name '$name' -- -c \"$terminal_command\"; exec bash"
                ;;

            lxterminal)
                lxterminal -e "bash -lc \"sbx run --name '$name' -- -c \\\"$terminal_command\\\"; exec bash\""
                ;;

            xterm)
                xterm -e bash -lc \
                    "sbx run --name '$name' -- -c \"$terminal_command\"; exec bash"
                ;;

            x-terminal-emulator)
                x-terminal-emulator -e bash -lc \
                    "sbx run --name '$name' -- -c \"$terminal_command\"; exec bash"
                ;;

        esac

    else

        # Headless fallback: run in the background.
        nohup sbx run --name "$name" -- -c "$terminal_command" \
            > "$log_file" 2>&1 < /dev/null &

        success "Started in background. Log: $log_file"

    fi

done < <(jq -c '.sandboxes[] | select(.enabled == true)' "$CONFIG_FILE")

# --------------------------------------------
# Finished
# --------------------------------------------

echo
echo "========================================"
success "Sandbox manager finished."
echo "Enabled sandboxes: $enabled_count"
echo "========================================"
