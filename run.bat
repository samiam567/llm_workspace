
@echo off
setlocal

title OpenTerminal Multi-Sandbox Manager

echo ==========================================
echo     OpenTerminal Multi-Sandbox Manager
echo ==========================================
echo.

:: Check configuration
if not exist "%~dp0sandboxes.json" (
    echo ERROR: sandboxes.json not found!
    pause
    exit /b 1
)

:: Check PowerShell manager
if not exist "%~dp0run-sandboxes.ps1" (
    echo ERROR: run-sandboxes.ps1 not found!
    pause
    exit /b 1
)

:: Launch manager
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-sandboxes.ps1"

if errorlevel 1 (
    echo.
    echo ERROR: Sandbox manager encountered an error.
) else (
    echo.
    echo All enabled sandboxes processed successfully.
)

echo "Press Enter To Exit"
pause

docker compose down
