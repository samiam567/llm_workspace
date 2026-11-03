bla bla bla


# Installation

## Step 1:
Set the following variables in a file named ".env" in this directory
~~~
SANDBOX_NAME=
WORKSPACE_PATH=
~~~
Use
~~~
openssl rand -hex 32
~~~
To generate keys for 
~~~
LLAMACPP_API_KEY=
OPENTERMINAL_API_KEY=
LITELLM_MASTER_KEY=
~~~
Then fill in your provider keys for the following providers (available with a free account):
~~~
OPENROUTER_API_KEY=
GOOGLE_AI_STUDIO_API_KEY=
GROQ_API_KEY=
~~~
You will need to fill these key in for openwebui

## Windows Environment Setup Guide

Follow the steps below to set up **Docker Desktop** and the **Docker Sandboxes (`sbx`) CLI** on Windows.

---

### Step 1: Install Docker Desktop

1. Visit the official installation portal:
   - **[Docker Desktop for Windows Installation Guide](https://docs.docker.com/desktop/setup/install/windows-install/)**
2. Download and run the installer, ensuring WSL 2 support is enabled when prompted.
3. Restart your computer if required, and make sure Docker Desktop is running before proceeding.

---

### Step 2: Install Docker Sandboxes (`sbx`)

1. Review the official documentation and setup details:
   - **[Docker Sandboxes (`sbx`) Documentation](https://github.com/docker/labs-ai-tools-for-devs)** *(or follow the CLI installation steps provided in your Docker/sandbox portal)*.
2. Install the `sbx` CLI tool in your terminal (PowerShell or Command Prompt).

---

### Step 3: Authenticate & Run

1. Authenticate your sandbox CLI by running:
   ```cmd
   sbx login

## Linux

### Step 2: Install Docker & Docker Sandboxees
Install docker and docker sandboxes by fdollowing the instructions on [Docker's Website](https://docs.docker.com/ai/sandboxes/install/)

Note: DO NOT install docker desktop when using Linux. This can cause issues.


### Step 2: Authenticate & Run

1. Authenticate your sandbox CLI by running:
   ```cmd
   sbx login


# Configuration

### OpenWebUI Access
Go to [OpenWebUI](http://localhost:3000/) to configure the webui. This is the hub where you can control the entire repo.

### ComfyUI Web Access
Go to [ComfyUI Web Interface](http://localhost:8188/) to configure workflows and settings. Access the settings for the AutoFreeMemory plugin to configure ComfyUI to automatically unload image generation models