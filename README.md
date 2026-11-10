# Installation and Setup

This repository provides a self-hosted AI environment using Docker Compose, Docker Sandboxes, Open WebUI, llama.cpp, LiteLLM, ComfyUI, and OpenTerminal.

Open WebUI serves as the central interface for interacting with your models and tools. Multiple independent Docker Sandboxes can be configured and connected to separate OpenTerminal instances.

---

# 1. Initial Configuration

## Step 1: Configure environment variables

Create a file named `.env` in the repository root.

Add the following variables:

```env
LLAMACPP_API_KEY=
LITELLM_MASTER_KEY=
```

Generate secure random API keys using:

```bash
openssl rand -hex 32
```

Use the generated keys for:

- `LLAMACPP_API_KEY`
- `LITELLM_MASTER_KEY`

## Step 2: Configure provider API keys

Add your provider API keys to `.env`.

The following providers offer free account tiers:

```env
OPENROUTER_API_KEY=
GOOGLE_AI_STUDIO_API_KEY=
GROQ_API_KEY=
```

You can configure additional providers as needed.

These keys are used by LiteLLM to authenticate with the respective providers.

## Step 3: Configure OpenTerminal sandboxes

Sandbox configuration is managed separately through `sandboxes.json`.

See [Section 4: Sandbox Configuration](#4-sandbox-configuration).

**Important:** Do not commit your actual `.env` or `sandboxes.json` files to a public repository. Keep API keys private.

---

# 2. Windows Environment Setup

Follow these steps to install Docker Desktop and Docker Sandboxes (`sbx`) on Windows.

## Step 1: Install Docker Desktop

1. Visit the official [Docker Desktop for Windows Installation Guide](https://docs.docker.com/desktop/setup/install/windows-install/).
2. Download and run the installer.
3. Ensure WSL 2 support is enabled.
4. Restart your computer if required.
5. Start Docker Desktop before proceeding.

## Step 2: Install Docker Sandboxes (`sbx`)

1. Review the official [Docker Sandboxes documentation](https://docs.docker.com/ai/sandboxes/install/).
2. Install the `sbx` CLI following the instructions for your environment.
3. Verify that the CLI is available:

```powershell
sbx --help
```

## Step 3: Authenticate

Authenticate your sandbox CLI:

```powershell
sbx login
```

Verify that Docker and the sandbox CLI are working before continuing.

---

# 3. Linux Environment Setup

The Linux startup scripts use Bash and require Docker, Docker Compose, Docker Sandboxes, and `jq`.

## Step 1: Install Docker and Docker Compose

Follow the official [Docker Engine installation instructions](https://docs.docker.com/engine/install/).

Install the Docker Compose plugin as described in the Docker documentation.

**Important:** Do not install Docker Desktop when using Linux. Use the native Docker Engine installation instead.

Verify the installation:

```bash
docker --version
docker compose version
```

## Step 2: Install Docker Sandboxes (`sbx`)

Follow the official [Docker Sandboxes installation instructions](https://docs.docker.com/ai/sandboxes/install/).

Verify that the CLI is available:

```bash
sbx --help
```

## Step 3: Install script dependencies

On Debian or Ubuntu:

```bash
sudo apt update
sudo apt install -y jq coreutils
```

The scripts also require Bash.

Verify:

```bash
bash --version
jq --version
```

## Step 4: Authenticate

Authenticate your sandbox CLI:

```bash
sbx login
```

Verify that Docker and `sbx` are working before continuing.

---

# 4. Sandbox Configuration

Multiple independent sandboxes and OpenTerminal instances are managed through a single JSON configuration file.

This eliminates the need to manually configure each sandbox in the startup scripts.

## Step 1: Create `sandboxes.json`

An example configuration is provided in the repository:

```text
sandboxes.example.json
```

Copy this file and rename the copy to:

```text
sandboxes.json
```

Edit `sandboxes.json` to configure your sandboxes.

**Do not edit `sandboxes.example.json` directly.** Keep it as a reusable template.

## Step 2: Configure your sandboxes

Each sandbox has its own configuration entry.

Example:

```json
{
  "sandboxes": [
    {
      "sandbox-name": "llm-workspace",
      "sandbox-workspace-folder": "./opencode_workspace",
      "sandbox-api-key": "YOUR_SECRET_KEY_1",
      "sandbox-port": 8000,
      "enabled": true
    },
    {
      "sandbox-name": "coding-workspace",
      "sandbox-workspace-folder": "./coding_workspace",
      "sandbox-api-key": "YOUR_SECRET_KEY_2",
      "sandbox-port": 8001,
      "enabled": true
    },
    {
      "sandbox-name": "cad-workspace",
      "sandbox-workspace-folder": "./cad_workspace",
      "sandbox-api-key": "YOUR_SECRET_KEY_3",
      "sandbox-port": 8002,
      "enabled": false
    }
  ]
}
```

## Configuration Properties

| Property | Description |
|---|---|
| `sandbox-name` | Unique name assigned to the Docker Sandbox. |
| `sandbox-workspace-folder` | Workspace directory mounted into the sandbox. Relative paths are resolved from the repository directory. |
| `sandbox-api-key` | Secret API key used to authenticate with OpenTerminal. |
| `sandbox-port` | Unique host port used to access that sandbox's OpenTerminal instance. |
| `enabled` | Controls whether the sandbox is processed by the startup script. |

### Important configuration rules

- Each sandbox must have a unique name.
- Each enabled sandbox must have a unique host port.
- Each sandbox should have its own API key.
- Workspace folders are created automatically if they don't exist.
- Disabled sandboxes are skipped.
- OpenTerminal listens on port `8000` inside every sandbox. The configured `sandbox-port` determines the host-side port.

For example:

| Sandbox | Host port | Internal port |
|---|---:|---:|
| llm-workspace | 8000 | 8000 |
| coding-workspace | 8001 | 8000 |
| cad-workspace | 8002 | 8000 |

---

# 5. Starting and Managing Sandboxes

The repository includes separate startup scripts for Windows and Linux.

```text
run.bat
run-sandboxes.ps1

run.sh
run-sandboxes.sh
```

Both platforms use the same `sandboxes.json` configuration format.

## Windows

Double-click:

```text
run.bat
```

Alternatively, run the PowerShell manager directly:

```powershell
.\run-sandboxes.ps1
```

The batch launcher checks that the configuration and PowerShell manager exist, then launches the manager.

## Linux

First, make the scripts executable:

```bash
chmod +x run.sh run-sandboxes.sh
```

Then run:

```bash
./run.sh
```

Alternatively, run the Bash manager directly:

```bash
./run-sandboxes.sh
```

The Bash launcher checks that the configuration and manager script exist, then launches the manager.

### Linux script dependencies

The Linux manager requires:

- Bash
- Docker
- Docker Compose plugin
- Docker Sandboxes (`sbx`)
- `jq`
- Standard utilities such as `base64`, `grep`, and `realpath`

The Linux manager also looks for an available terminal emulator. It supports common Linux desktop terminals, including GNOME Terminal, Konsole, Xfce Terminal, MATE Terminal, LXTerminal, and xterm.

If no supported terminal emulator is available, OpenTerminal instances are launched in the background. Their output is written to:

```text
logs/<sandbox-name>.log
```

### What the manager does

Both managers follow the same general workflow:

1. Read `sandboxes.json`.
2. Validate the enabled sandbox configurations.
3. Start Docker Compose services.
4. Check whether each sandbox already exists.
5. Create missing sandboxes.
6. Configure the OpenTerminal port mapping for newly created sandboxes.
7. Install OpenTerminal in newly created sandboxes.
8. Launch a separate OpenTerminal process for each enabled sandbox.

Existing sandboxes are reused rather than recreated.

**Note:** Existing port mappings are not automatically modified. If you change the port of an existing sandbox, you must update its existing mapping or recreate the sandbox.

Docker Compose is intentionally left running after the manager finishes.

### Enabling and disabling sandboxes

To temporarily disable a sandbox, change:

```json
"enabled": true
```

to:

```json
"enabled": false
```

The sandbox configuration is retained, but the startup manager skips it.

To enable it again, change the value back to `true`.

---

# 6. Connecting OpenTerminal to Open WebUI

Each sandbox runs an independent OpenTerminal instance.

OpenTerminal listens on port `8000` inside the sandbox. The configured host port makes it accessible to other services running on the host or Docker network.

## OpenTerminal connection addresses

When connecting from Open WebUI, use:

```text
http://host.docker.internal:PORT
```

Replace `PORT` with the corresponding `sandbox-port` from `sandboxes.json`.

Example:

| Sandbox | OpenTerminal API URL |
|---|---|
| llm-workspace | `http://host.docker.internal:8000` |
| coding-workspace | `http://host.docker.internal:8001` |
| cad-workspace | `http://host.docker.internal:8002` |

Use the corresponding `sandbox-api-key` for authentication.

Configure each OpenTerminal connection independently in Open WebUI, using its respective URL and API key.

**Important:** Do not use `localhost` when connecting from inside the Open WebUI container. `localhost` refers to the Open WebUI container itself, not your host machine.

### Linux networking note

On Linux, `host.docker.internal` may not resolve automatically when using native Docker Engine.

If necessary, add the following to the Open WebUI service in your Docker Compose configuration:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

Recreate the Open WebUI container after changing the Compose configuration.

## Network architecture

```text
                  Host Machine
                       |
          +------------+------------+
          |                         |
     Docker Compose            Docker Sandboxes
          |                         |
      Open WebUI              llm-workspace
          |                   OpenTerminal
          |                   Internal: 8000
          |                   Host: 8000
          |
          |                   coding-workspace
          |                   OpenTerminal
          |                   Internal: 8000
          |                   Host: 8001
          |
          |                   cad-workspace
          |                   OpenTerminal
          |                   Internal: 8000
          |                   Host: 8002
          |
          +---- host.docker.internal
```

Each sandbox has its own workspace, OpenTerminal process, port, and API key.

---

# 7. Open WebUI Configuration

Open WebUI is the central interface for interacting with the models and tools in this repository.

Access it locally:

[http://localhost:3000/](http://localhost:3000/)

Configure your model connections, LiteLLM integration, OpenTerminal connections, and other tools through the Open WebUI interface.

## Access Open WebUI over Tailscale

To make Open WebUI accessible from other devices on your Tailscale network, run:

```bash
tailscale serve --bg 3000
```

Tailscale will provide a URL that can be used to access Open WebUI from your other authenticated devices.

---

# 8. ComfyUI Configuration

ComfyUI provides the image-generation backend used by Open WebUI.

Access the ComfyUI web interface locally:

[http://localhost:8188/](http://localhost:8188/)

Use the interface to configure workflows, models, and custom nodes.

## AutoFreeMemory

This installation uses the AutoFreeMemory plugin to help manage GPU memory.

Open the ComfyUI settings and configure AutoFreeMemory to automatically unload image-generation models when they are no longer needed.

This helps free GPU memory for other workloads, particularly llama.cpp.

---

# 9. Troubleshooting

## Sandbox already exists

Existing sandboxes are reused automatically. The manager does not recreate them.

## OpenTerminal connection fails

Check the following:

1. Verify that the sandbox is running.
2. Verify that OpenTerminal is listening on port `8000` inside the sandbox.
3. Verify that the correct host port is published.
4. Verify that Open WebUI is using `host.docker.internal` rather than `localhost`.
5. On Linux, verify that `host.docker.internal` resolves from the Open WebUI container.
6. Verify that the API key matches the corresponding entry in `sandboxes.json`.

To inspect listening ports inside a sandbox:

```bash
ss -tulpn
```

To list existing sandboxes:

```bash
sbx list
```

## Port conflicts

Every enabled sandbox must have a unique host port.

If another application is already using a configured port, choose another available port in `sandboxes.json`.

Remember that changing the port in the JSON file does not automatically update an existing sandbox's port mapping.

## OpenTerminal installation issues

OpenTerminal is installed inside newly created sandboxes using:

```bash
python3 -m pip install --upgrade open-terminal --break-system-packages
```

If installation fails, enter the affected sandbox and run the installation command manually.

## Linux manager does not start

Verify the dependencies:

```bash
docker --version
docker compose version
sbx --help
jq --version
```

Verify that both scripts are executable:

```bash
chmod +x run.sh run-sandboxes.sh
```

If running without a desktop environment, check the relevant log:

```text
logs/<sandbox-name>.log
```

---

# 10. Security Notes

- Never commit `.env` or `sandboxes.json` containing real API keys.
- Use unique API keys for each OpenTerminal instance.
- Keep Docker Desktop, Docker Engine, and Docker Sandboxes updated.
- Avoid exposing OpenTerminal ports publicly unless absolutely necessary.
- Prefer restricting published ports to trusted interfaces and networks.
- Use Tailscale or another authenticated private network for remote access.

---

# Useful Links

- [Docker Desktop Installation](https://docs.docker.com/desktop/setup/install/windows-install/)
- [Docker Engine Installation](https://docs.docker.com/engine/install/)
- [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/install/)
- [Open WebUI](https://docs.openwebui.com/)
- [ComfyUI](https://github.com/comfyanonymous/ComfyUI)
- [LiteLLM](https://docs.litellm.ai/)
- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- [Tailscale](https://tailscale.com/)