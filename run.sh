#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    export $(cat .env | xargs)
else
    echo "Warning: .env file not found! OPENCODE_SERVER_PASSWORD may be undefined."
fi

echo "Starting Docker Compose stack..."
docker compose up -d

echo "Preparing configuration..."
cd opencode_workspace

# Ensure config directory and opencode.json exist locally in the mounted workspace folder
mkdir -p .config/opencode
if [ ! -f "opencode.json" ]; then
    echo "{}" > opencode.json
fi

cp opencode.json .config/opencode/opencode.json


echo "Launching sbx environment for opencode..."

# Run sbx with the correct flags and direct server invocation
sbx run -e OPENCODE_SERVER_PASSWORD="$OPENCODE_SERVER_PASSWORD" \
    --publish 0.0.0.0:4096:4096 \
    opencode -- serve --hostname 0.0.0.0 --port 4096 --cors '*'

echo "Stopping Docker Compose Stack"
cd ..
docker compose down

echo "Done."