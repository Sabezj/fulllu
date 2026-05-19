@echo off
set SCRIPT_DIR=%~dp0
set PS1=%SCRIPT_DIR%start_all.ps1

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
pause
