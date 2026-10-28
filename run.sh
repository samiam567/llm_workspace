#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Error handling function to clean up and exit
handle_error() {
    echo "An error occurred. Exiting."
    # Return to the root directory if we are currently inside opencode_workspace
    cd .. 2>/dev/null || true
    docker compose down
    exit 1
}

# Trap any errors to trigger the cleanup
trap 'handle_error' ERR

# Load environment variables from .env file if it exists
if [ -f ".env" ]; then
    set -a
    source .env
    set +a
else
    echo "Warning: .env file not found! OPENCODE_SERVER_PASSWORD may be undefined."
fi

echo "Starting Docker Compose stack..."
docker compose up -d

echo "Preparing configuration..."
cd opencode_workspace

cp ../opencode.json .config/opencode/opencode.json
cp ../setup_opencode.sh .

echo "Launching sbx environment for opencode..."
sbx run -e OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD}" \
    --publish 0.0.0.0:4096:4096 \
    opencode -- serve --hostname 0.0.0.0 --port 4096 --cors "*"

echo "Stopping Docker Compose Stack..."
cd ..
docker compose down

echo "Done."
exit 0