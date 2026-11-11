
# ============================================
# Multi-Sandbox OpenTerminal Manager
# ============================================

$ErrorActionPreference = "Stop"

# Configuration paths
$ScriptDir = $PSScriptRoot
$ConfigFile = Join-Path $ScriptDir "sandboxes.json"

# --------------------------------------------
# Load and validate configuration
# --------------------------------------------

if (!(Test-Path $ConfigFile)) {
    Write-Host "ERROR: sandboxes.json not found." -ForegroundColor Red
    exit 1
}

$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

if (!$config.sandboxes -or $config.sandboxes.Count -eq 0) {
    Write-Host "No sandboxes configured." -ForegroundColor Yellow
    exit 0
}

$enabled = @($config.sandboxes | Where-Object { $_.enabled -eq $true })

# Validate unique names and ports
$names = @($enabled | ForEach-Object { $_.'sandbox-name' })
$ports = @($enabled | ForEach-Object { $_.'sandbox-port' })
# $controlPorts = @($enabled | ForEach-Object { $_.'sandbox-control-port' })

if (($names | Select-Object -Unique).Count -ne $names.Count) {
    throw "Duplicate sandbox names detected."
}

if (($ports | Select-Object -Unique).Count -ne $ports.Count) {
    throw "Duplicate OpenTerminal ports detected."
}

# if (($controlPorts | Select-Object -Unique).Count -ne $controlPorts.Count) {
#     throw "Duplicate control ports detected."
# }

# --------------------------------------------
# Start Docker Compose
# --------------------------------------------

Write-Host "`nStarting Docker Compose..." -ForegroundColor Cyan

Push-Location $ScriptDir

try {
    docker compose up -d

    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose failed to start."
    }
}
finally {
    Pop-Location
}

# --------------------------------------------
# Process each sandbox
# --------------------------------------------

foreach ($sandbox in $enabled) {

    $name = $sandbox.'sandbox-name'
    $workspace = $sandbox.'sandbox-workspace-folder'
    $apiKey = $sandbox.'sandbox-api-key'
    $port = [int]$sandbox.'sandbox-port'
    # $controlPort = [int]$sandbox.'sandbox-control-port'

    Write-Host "`n========================================" -ForegroundColor DarkGray
    Write-Host "Processing sandbox: $name" -ForegroundColor Cyan
    Write-Host "Workspace: $workspace"
    Write-Host "OpenTerminal port: $port"
    # Write-Host "Control port: $controlPort"
    Write-Host "========================================"

    # Validate required settings
    if ([string]::IsNullOrWhiteSpace($name) -or
        [string]::IsNullOrWhiteSpace($workspace) -or
        [string]::IsNullOrWhiteSpace($apiKey) -or
        $apiKey -like "YOUR_SECRET*") {

        Write-Host "Invalid configuration for $name. Skipping." -ForegroundColor Red
        continue
    }

    # Resolve workspace relative to script directory
    if (![System.IO.Path]::IsPathRooted($workspace)) {
        $workspace = Join-Path $ScriptDir $workspace
    }

    # Create workspace if missing
    if (!(Test-Path $workspace)) {
        New-Item -ItemType Directory -Path $workspace -Force | Out-Null
        Write-Host "Created workspace: $workspace" -ForegroundColor Green
    }

    # Check whether sandbox exists
    $sandboxList = sbx list 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Unable to retrieve sandbox list." -ForegroundColor Red
        continue
    }

    $exists = $false

    foreach ($line in $sandboxList) {
        if ($line -match "(?<![\w-])$([regex]::Escape($name))(?![\w-])") {
            $exists = $true
            break
        }
    }

    # Create sandbox if necessary
    if (!$exists) {

        Write-Host "Creating sandbox $name..." -ForegroundColor Yellow

        # --------------------------------------------
        # Optional sandbox disk configuration
        # --------------------------------------------

        $rootSize = $sandbox.'sandbox-root-size'
        $dockerSize = $sandbox.'sandbox-docker-size'

        # Set disk sizes only when specified
        if (![string]::IsNullOrWhiteSpace($rootSize)) {
            Write-Host "Root filesystem size: $rootSize" -ForegroundColor Cyan
            $env:DOCKER_SANDBOXES_ROOT_SIZE = $rootSize
        }

        if (![string]::IsNullOrWhiteSpace($dockerSize)) {
            Write-Host "Docker storage size: $dockerSize" -ForegroundColor Cyan
            $env:DOCKER_SANDBOXES_DOCKER_SIZE = $dockerSize
        }

        # Create sandbox
        sbx create --name $name shell $workspace

        # Clear environment variables to avoid affecting other sandboxes
        Remove-Item Env:DOCKER_SANDBOXES_ROOT_SIZE -ErrorAction SilentlyContinue
        Remove-Item Env:DOCKER_SANDBOXES_DOCKER_SIZE -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -ne 0) {
            Write-Host "Sandbox creation failed." -ForegroundColor Red
            continue
        }


        if ($LASTEXITCODE -ne 0) {
            Write-Host "Sandbox creation failed." -ForegroundColor Red
            continue
        }

        # Publish ports
        # sbx ports $name --publish "0.0.0.0:$controlPort`:4096"
        sbx ports $name --publish "0.0.0.0:$port`:8000"

        if ($LASTEXITCODE -ne 0) {
            Write-Host "Port configuration failed." -ForegroundColor Red
            continue
        }

        Write-Host "Installing OpenTerminal..." -ForegroundColor Yellow

        sbx exec $name bash -c "python3 -m pip install --upgrade open-terminal --break-system-packages"

        if ($LASTEXITCODE -ne 0) {
            Write-Host "OpenTerminal installation failed." -ForegroundColor Red
            continue
        }

        Write-Host "Sandbox created successfully." -ForegroundColor Green
    }
    else {
        Write-Host "Sandbox '$name' already exists." -ForegroundColor Green
        Write-Host "It will be started automatically by sbx run." -ForegroundColor Cyan
        Write-Host "Existing port mappings are left unchanged." -ForegroundColor Yellow
    }

    # Encode API key to safely pass it into the sandbox shell
    $encodedKey = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($apiKey)
    )

    # Construct OpenTerminal launch command
    $terminalCommand = "KEY=`$(printf '%s' '$encodedKey' | base64 -d); open-terminal run --host 0.0.0.0 --port 8000 --api-key `"`$KEY`""

    $runCommand = "sbx run --name `"$name`" -- -c `"$terminalCommand`""

    # Launch each OpenTerminal in its own window
    Write-Host "Launching OpenTerminal for $name on port $port..." -ForegroundColor Green

    Start-Process -FilePath "cmd.exe" -ArgumentList @(
        "/k",
        $runCommand
    )
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Sandbox manager finished." -ForegroundColor Green
Write-Host "Enabled sandboxes: $($enabled.Count)"
Write-Host "========================================"
