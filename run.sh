#!/bin/bash

SANDBOX_NAME="llm-workspace"

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
else
    echo "Warning: .env file not found! OPENCODE_SERVER_PASSWORD may be undefined."
fi

# Start the docker compose 
docker compose up -d

# configure sandbox

# Check if the sandbox name exists in the output of 'sbx list'
if sbx list | grep -q "$SANDBOX_NAME"; then
    echo "Sandbox '$SANDBOX_NAME' already exists. Skipping creation."
    sbx start "$SANDBOX_NAME" 2>/dev/null
else
    echo "Sandbox '$SANDBOX_NAME' not found. Creating..."
    sbx create --name "$SANDBOX_NAME" shell ./opencode_workspace
    sbx ports llm-workspace --publish 0.0.0.0:4096:4096
    sbx ports llm-workspace --publish 0.0.0.0:8000:8000
    sbx exec llm-workspace bash -c "python3 -m pip install open-terminal --break-system-packages"
    echo "Sandbox created successfully."
fi

sbx run llm-workspace -- -c "open-terminal run --host 0.0.0.0 --port 8000 --api-key sbxfsdf"

# stop the docker when completed
docker compose down