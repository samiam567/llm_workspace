#!/bin/bash

# Exit immediately if any command fails
set -e

echo "=== 1. Updating system package index ==="
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg

echo "=== 2. Installing Docker Engine and Docker Sandboxes (sbx) ==="
# Using Docker's official convenience script with SBX=1 flag to install both Docker and sbx
curl -fsSL https://get.docker.com | sudo SBX=1 sh

echo "=== 3. Configuring docker permissions for local sandboxes ==="
# Ensure docker hardware virtualization group exists and add current user
if getent group docker > /dev/null; then
    sudo usermod -aG docker "$USER"
    echo "Added $USER to the 'docker' group."
else
    echo "Warning: 'docker' group not found. Ensure hardware virtualization is enabled in your BIOS/VM settings."
fi

# Ensure docker group exists and add current user
sudo usermod -aG docker "$USER"

echo "=== 4. Verifying sbx installation ==="
if command -v sbx &> /dev/null; then
    echo "Success: sbx CLI is installed."
    sbx --version
else
    echo "Note: sbx installed, but you may need to restart your shell session for PATH updates."
fi

echo "===================================================="
echo "Setup complete!"
echo "IMPORTANT: To apply group changes (docker), please either:"
echo "  1. Run: newgrp docker"
echo "  2. Or log out and log back in."
echo ""
echo "Afterwards, authenticate your sbx CLI by running:"
echo "  sbx login"
echo "===================================================="