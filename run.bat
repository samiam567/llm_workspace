@echo off
set "SANDBOX_NAME=llm-workspace"
setlocal enabledelayedexpansion

:: Load environment variables from .env file if it exists
if exist .env (
    for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
        set "%%A=%%B"
    )
) else (
    echo Warning: .env file not found! OPENCODE_SERVER_PASSWORD may be undefined.
)

:: Start the docker compose 
docker compose up -d


:: configure sandbox


:: Check if the sandbox name exists in the output of 'sbx list'
sbx list | findstr /C:"%SANDBOX_NAME%" >nul 2>&1

if %errorlevel% equ 0 (
    echo Sandbox '%SANDBOX_NAME%' already exists. Skipping creation.
    sbx start %SANDBOX_NAME% 2>nul
) else (
    echo Sandbox '%SANDBOX_NAME%' not found. Creating...
    sbx create --name %SANDBOX_NAME% shell .\opencode_workspace
    sbx ports llm-workspace --publish 0.0.0.0:4096:4096
    sbx ports llm-workspace --publish 0.0.0.0:8000:8000
    sbx exec llm-workspace bash -c "python3 -m pip install open-terminal --break-system-packages"
    echo Sandbox created successfully.
)


sbx run llm-workspace -- -c "open-terminal run --host 0.0.0.0 --port 8000 --api-key sbxfsdf"

:: stop the docker when completed
docker compose down