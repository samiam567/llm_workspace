@echo off
setlocal enabledelayedexpansion

:: Create a default .env file if it doesn't exist
if not exist .env (
    echo .env file not found. Creating a default .env file...
    (
        echo SANDBOX_NAME=llm-workspace
        echo WORKSPACE_PATH=.\workspace
        echo API_KEY=your_actual_secret_key
    ) > .env
    echo Default .env created successfully. Please update it with your actual settings if needed.
    echo.
)

:: Load environment variables from .env file
for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
    set "%%A=%%B"
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
    sbx create --name %SANDBOX_NAME% shell %WORKSPACE_PATH%
    sbx ports %SANDBOX_NAME% --publish 0.0.0.0:4096:4096
    sbx ports %SANDBOX_NAME% --publish 0.0.0.0:8000:8000
    sbx exec %SANDBOX_NAME% bash -c "python3 -m pip install open-terminal --break-system-packages"
    echo Sandbox created successfully.
)

:: Run using the API_KEY loaded from the .env file
sbx run --name %SANDBOX_NAME% -- -c "open-terminal run --host 0.0.0.0 --port 8000 --api-key %API_KEY%"

:: stop the docker when completed
docker compose down