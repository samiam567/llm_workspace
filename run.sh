#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Create a default .env file if it doesn't exist
if [ ! -f .env ]; then
    echo ".env file not found. Creating a default .env file..."
    cat << 'EOF' > .env
SANDBOX_NAME=llm-workspace
WORKSPACE_PATH=./workspace
API_KEY=your_actual_secret_key
EOF
    echo "Default .env created successfully. Please update it with your actual settings if needed."
    echo ""
fi

# Load environment variables from .env file securely
set -a
source .env
set +a

# Start the docker compose
docker compose up -d

# Configure sandbox
# Check if the sandbox name exists in the output of 'sbx list'
if sbx list | grep -q "$SANDBOX_NAME"; then
    echo "Sandbox '$SANDBOX_NAME' already exists. Skipping creation."
    sbx start "$SANDBOX_NAME" >/dev/null 2>&1 || true
else
    echo "Sandbox '$SANDBOX_NAME' not found. Creating..."
    sbx create --name "$SANDBOX_NAME" shell "$WORKSPACE_PATH"
    sbx ports "$SANDBOX_NAME" --publish 0.0.0.0:4096:4096
    sbx ports "$SANDBOX_NAME" --publish 0.0.0.0:8000:8000
    sbx exec "$SANDBOX_NAME" bash -c "python3 -m pip install open-terminal --break-system-packages"
    echo "Sandbox created successfully."
fi

# Run using the API_KEY loaded from the .env file
sbx run --name "$SANDBOX_NAME" -- -c "open-terminal run --host 0.0.0.0 --port 8000 --api-key $API_KEY"

# Stop the docker when completed
docker compose down