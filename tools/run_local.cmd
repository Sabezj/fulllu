@echo off
REM Simple batch file to run the voice agent application locally
REM This provides a minimal way to run the application with basic checks

echo Starting local application runner...
echo.

REM Check if Node.js is installed
where node >nul 2>nul
if %errorlevel% neq 0 (
    echo ERROR: Node.js is not installed or not in PATH.
    echo Please install Node.js from https://nodejs.org/
    pause
    exit /b 1
)

REM Check if npm is installed
where npm >nul 2>nul
if %errorlevel% neq 0 (
    echo ERROR: npm is not installed or not in PATH.
    echo Please install Node.js (which includes npm) from https://nodejs.org/
    pause
    exit /b 1
)

REM Show versions
echo Checking versions:
node --version
npm --version
echo.

REM Check if .env file exists
if not exist ".env" (
    echo WARNING: .env file not found.
    echo Some environment variables may be missing.
    echo.
)

REM Check if port 3000 is in use (basic check)
netstat -an | findstr ":3000 " | findstr "LISTENING" >nul
if %errorlevel% equ 0 (
    echo WARNING: Port 3000 appears to be in use.
    echo You may need to change the PORT in .env file.
    echo.
)

REM Start the application
echo Starting application...
echo Application will be available at: http://localhost:3000
echo Press Ctrl+C to stop the application
echo.

npm start

if %errorlevel% neq 0 (
    echo.
    echo ERROR: Application failed to start.
    echo Check the error messages above for details.
    pause
    exit /b 1
)