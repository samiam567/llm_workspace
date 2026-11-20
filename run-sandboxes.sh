
#!/usr/bin/env bash

# ============================================
# OpenTerminal Multi-Sandbox Manager
# WSL2 / Native Ubuntu
# Detached tmux sessions
# Configurable sandbox port publishing
# ============================================

set -uo pipefail

# --------------------------------------------
# Configuration
# --------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/sandboxes.json"
LOG_DIR="$SCRIPT_DIR/logs"

mkdir -p "$LOG_DIR"

# --------------------------------------------
# Helpers
# --------------------------------------------

info() {
    printf '\033[36m%s\033[0m\n' "$*"
}

success() {
    printf '\033[32m%s\033[0m\n' "$*"
}

warning() {
    printf '\033[33m%s\033[0m\n' "$*"
}

error() {
    printf '\033[31mERROR: %s\033[0m\n' "$*" >&2
}

fail() {
    error "$*"
    exit 1
}

# Validate IPv4 address.
valid_ipv4() {
    local ip="$1"
    local -a octets

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1

    IFS='.' read -r -a octets <<< "$ip"

    [[ ${#octets[@]} -eq 4 ]] || return 1

    local octet
    for octet in "${octets[@]}"; do
        (( ${#octet} <= 3 )) || return 1
        (( 10#$octet <= 255 )) || return 1
    done

    return 0
}

# Validate port number.
valid_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( ${#port} <= 5 )) || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

# Validate mapping: IP:HOST_PORT:SANDBOX_PORT
valid_mapping() {
    local mapping="$1"
    local ip host_port sandbox_port

    IFS=':' read -r ip host_port sandbox_port <<< "$mapping"

    [[ -n "$ip" && -n "$host_port" && -n "$sandbox_port" ]] || return 1

    valid_ipv4 "$ip" || return 1
    valid_port "$host_port" || return 1
    valid_port "$sandbox_port" || return 1

    return 0
}

# Check whether a host IP and port appear in the port list.
# sbx port list output is expected to include IP:PORT.
port_is_published() {
    local existing_ports="$1"
    local mapping="$2"

    local ip host_port sandbox_port
    IFS=':' read -r ip host_port sandbox_port <<< "$mapping"

    # Match the complete host binding, not just the port number.
    grep -Eq \
        "(^|[^0-9.])${ip//./\\.}:${host_port}([^0-9]|$)" \
        <<< "$existing_ports"
}

# --------------------------------------------
# Dependencies
# --------------------------------------------

for dependency in jq docker sbx tmux base64 realpath awk grep sort wc; do
    command -v "$dependency" >/dev/null 2>&1 ||
        fail "Missing dependency: $dependency"
done

docker info >/dev/null 2>&1 ||
    fail "Docker daemon is unavailable."

[[ -f "$CONFIG_FILE" ]] ||
    fail "sandboxes.json not found."

jq empty "$CONFIG_FILE" >/dev/null 2>&1 ||
    fail "Invalid JSON in sandboxes.json."

jq -e '.sandboxes | type == "array"' "$CONFIG_FILE" >/dev/null ||
    fail "Configuration must contain a sandboxes array."

# --------------------------------------------
# Enabled sandbox count
# --------------------------------------------

enabled_count=$(jq '[.sandboxes[] | select(.enabled == true)] | length' "$CONFIG_FILE")

if [[ "$enabled_count" -eq 0 ]]; then
    warning "No enabled sandboxes configured."
    exit 0
fi

# --------------------------------------------
# Validate unique names and OpenTerminal ports
# --------------------------------------------

names=$(jq -c '[.sandboxes[] | select(.enabled == true) | ."sandbox-name"]' "$CONFIG_FILE")
ports=$(jq -c '[.sandboxes[] | select(.enabled == true) | ."sandbox-port"]' "$CONFIG_FILE")

[[ $(jq 'unique | length' <<< "$names") -eq "$enabled_count" ]] ||
    fail "Duplicate sandbox names detected."

[[ $(jq 'unique | length' <<< "$ports") -eq "$enabled_count" ]] ||
    fail "Duplicate OpenTerminal ports detected."

# --------------------------------------------
# Start Docker Compose
# --------------------------------------------

info "Starting Docker Compose..."

cd "$SCRIPT_DIR" || fail "Unable to enter project directory."

docker compose up -d ||
    fail "Docker Compose failed."

success "Docker Compose is running."

# --------------------------------------------
# Start tmux server
# --------------------------------------------

tmux start-server 2>/dev/null || true

tmux set-window-option -g remain-on-exit on

# --------------------------------------------
# Process enabled sandboxes
# --------------------------------------------

while IFS= read -r sandbox; do

    name=$(jq -r '."sandbox-name" // empty' <<< "$sandbox")
    workspace=$(jq -r '."sandbox-workspace-folder" // empty' <<< "$sandbox")
    api_key=$(jq -r '."sandbox-api-key" // empty' <<< "$sandbox")
    port=$(jq -r '."sandbox-port" // empty' <<< "$sandbox")

    root_size=$(jq -r '."sandbox-root-size" // empty' <<< "$sandbox")
    docker_size=$(jq -r '."sandbox-docker-size" // empty' <<< "$sandbox")

    echo
    echo "=========================================="
    info "Processing sandbox: $name"
    echo "Workspace: $workspace"
    echo "OpenTerminal host port: $port"
    echo "=========================================="

    # ----------------------------------------
    # Validate configuration
    # ----------------------------------------

    if [[ -z "$name" ||
          -z "$workspace" ||
          -z "$api_key" ||
          "$api_key" == YOUR_SECRET* ]] ||
       ! valid_port "$port"; then

        error "Invalid configuration for $name. Skipping."
        continue
    fi

    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "Invalid sandbox name: $name"
        continue
    fi

    # ----------------------------------------
    # Resolve workspace
    # ----------------------------------------

    if [[ "$workspace" != /* ]]; then
        workspace="$SCRIPT_DIR/$workspace"
    fi

    workspace=$(realpath -m "$workspace")

    if [[ ! -d "$workspace" ]]; then
        mkdir -p "$workspace" ||
            { error "Unable to create workspace."; continue; }

        success "Created workspace: $workspace"
    fi

    # ----------------------------------------
    # Check sandbox existence
    # ----------------------------------------

    if ! sandbox_list=$(sbx list 2>&1); then
        error "Unable to retrieve sandbox list: $sandbox_list"
        continue
    fi

    exists=false

    if awk -v name="$name" '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == name) found = 1
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

        warning "Creating sandbox: $name"

        create_args=()

        if [[ -n "$root_size" ]]; then
            create_args+=("DOCKER_SANDBOXES_ROOT_SIZE=$root_size")
        fi

        if [[ -n "$docker_size" ]]; then
            create_args+=("DOCKER_SANDBOXES_DOCKER_SIZE=$docker_size")
        fi

        if [[ ${#create_args[@]} -gt 0 ]]; then
            if ! env "${create_args[@]}" sbx create \
                --name "$name" shell "$workspace"; then
                error "Sandbox creation failed."
                continue
            fi
        else
            if ! sbx create --name "$name" shell "$workspace"; then
                error "Sandbox creation failed."
                continue
            fi
        fi

        # Install OpenTerminal.
        warning "Installing OpenTerminal..."

        if ! sbx exec "$name" bash -c \
            "python3 -m pip install --upgrade open-terminal --break-system-packages"; then
            error "OpenTerminal installation failed."
            continue
        fi

        success "Sandbox created and OpenTerminal installed."

    else
        success "Sandbox already exists: $name"
    fi

    # ----------------------------------------
    # Configure published ports
    # ----------------------------------------

    # Always include the OpenTerminal mapping.
    publish_ports=(
        "0.0.0.0:$port:8000"
    )

    # Read additional configured mappings.
    if ! jq -e '
        (."sandbox-published-ports" // []) | type == "array"
    ' <<< "$sandbox" >/dev/null; then
        error "sandbox-published-ports must be an array for $name."
        continue
    fi

    while IFS= read -r mapping; do
        [[ -n "$mapping" ]] && publish_ports+=("$mapping")
    done < <(
        jq -r '."sandbox-published-ports"[]? // empty' <<< "$sandbox"
    )

    # Validate all mappings before applying them.
    port_config_valid=true

    for mapping in "${publish_ports[@]}"; do
        if ! valid_mapping "$mapping"; then
            error "Invalid port mapping: $mapping"
            port_config_valid=false
            break
        fi
    done

    if [[ "$port_config_valid" == false ]]; then
        error "Skipping port configuration for $name."
        continue
    fi

    # Reject duplicate mappings.
    unique_mappings=$(printf '%s\n' "${publish_ports[@]}" | sort -u)

    if [[ $(wc -l <<< "$unique_mappings") -ne ${#publish_ports[@]} ]]; then
        error "Duplicate port mappings configured for $name."
        continue
    fi

    # Reject duplicate host IP/host port combinations.
    host_bindings=()

    for mapping in "${publish_ports[@]}"; do
        IFS=':' read -r ip host_port sandbox_port <<< "$mapping"
        host_bindings+=("$ip:$host_port")
    done

    unique_bindings=$(printf '%s\n' "${host_bindings[@]}" | sort -u)

    if [[ $(wc -l <<< "$unique_bindings") -ne ${#host_bindings[@]} ]]; then
        error "Duplicate host IP/port bindings configured for $name."
        continue
    fi

   
    # ----------------------------------------
    # Apply port configuration (idempotent)
    # ----------------------------------------

    echo
    info "Applying port configuration to $name..."

    for mapping in "${publish_ports[@]}"; do

        IFS=':' read -r ip host_port sandbox_port <<< "$mapping"

        info "Publishing: $mapping"

        if publish_output=$(sbx port publish "$name" "$mapping" 2>&1); then
            success "Published: $mapping"
            continue
        fi

        # Treat an existing identical mapping as success.
        # Do not silently accept mappings targeting another port.
        if grep -Fq "already published to sandbox port $sandbox_port" \
            <<< "$publish_output"; then

            success "Already published: $mapping"
            continue
        fi

        error "Failed to publish $mapping on $name."
        error "$publish_output"
        port_config_valid=false
        break

    done

    if [[ "$port_config_valid" == false ]]; then
        error "One or more port mappings failed for $name."
        continue
    fi

    success "Port configuration applied."


    # ----------------------------------------
    # Construct launch command
    # ----------------------------------------

    encoded_key=$(printf '%s' "$api_key" | base64 -w 0)

    terminal_command="KEY=\$(printf '%s' '$encoded_key' | base64 -d); exec open-terminal run --host 0.0.0.0 --port 8000 --api-key \"\$KEY\""

    printf -v launch_command \
        'exec sbx run --name %q -- bash -lc %q' \
        "$name" "$terminal_command"

    # ----------------------------------------
    # tmux session
    # ----------------------------------------

    session="openterminal-$name"

    if tmux has-session -t "=$session" 2>/dev/null; then

        pane_dead=$(tmux display-message -p \
            -t "=$session:0.0" '#{pane_dead}' 2>/dev/null || echo 1)

        if [[ "$pane_dead" == "1" ]]; then

            warning "Restarting stopped OpenTerminal session: $name"

            if ! tmux respawn-pane -k \
                -t "=$session:0.0" "$launch_command"; then
                error "Unable to restart session: $session"
                continue
            fi

        else
            success "OpenTerminal already running: $name"
            info "Session: $session"
            continue
        fi

    else

        info "Creating tmux session: $session"

        if ! tmux new-session -d \
            -s "$session" \
            -n openterminal \
            "$launch_command"; then

            error "Unable to create tmux session: $session"
            continue
        fi

    fi

    success "OpenTerminal session started."
    info "Session: $session"
    info "Endpoint: http://localhost:$port"

done < <(jq -c '.sandboxes[] | select(.enabled == true)' "$CONFIG_FILE")

# --------------------------------------------
# Summary
# --------------------------------------------

echo
echo "=========================================="
success "Sandbox manager finished."
echo "Enabled sandboxes: $enabled_count"
echo "=========================================="

echo
info "OpenTerminal tmux sessions:"

tmux list-sessions -F '#{session_name}' 2>/dev/null |
    grep '^openterminal-' || true

echo
info "Attach to a session:"
echo "tmux attach -t openterminal-SANDBOX_NAME"

echo
info "Detach without stopping it: Ctrl+B, then D"
