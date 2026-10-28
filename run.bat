@echo off
setlocal enabledelayedexpansion

:: Load environment variables from .env file if it exists
if exist .env (
    for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
        set "%%A=%%B"
    )
) else (
    echo Warning: .env file not found! OPENCODE_SERVER_PASSWORD may be undefined.
)

echo Starting Docker Compose stack...
docker compose up -d
if errorlevel 1 goto :error

echo Preparing configuration...
cd opencode_workspace

:: Ensure config directory and opencode.json exist locally in the mounted workspace folder
if not exist ".config\opencode" mkdir .config\opencode
if not exist "opencode.json" echo {} > opencode.json
copy opencode.json .config\opencode\opencode.json >nul

echo Launching sbx environment for opencode...

:: Run sbx with the correct flags and direct server invocation
sbx run -e OPENCODE_SERVER_PASSWORD="%OPENCODE_SERVER_PASSWORD%" ^
    --publish 0.0.0.0:4096:4096 ^
    opencode -- serve --hostname 0.0.0.0 --port 4096 --cors "*"
if errorlevel 1 goto :error

echo Stopping Docker Compose Stack...
cd ..
docker compose down

echo Done.
exit /b 0

:error
echo An error occurred. Exiting.
cd ..
docker compose down
exit /b 1