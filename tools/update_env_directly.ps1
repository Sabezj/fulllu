# Update .env file directly on VPS
# Root cause: sed command didn't properly update DATABASE_URL in .env

$ErrorActionPreference = "Stop"

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"
$VPS_PROJECT_DIR = "/opt/sed-lex-voice"
$PROJECT_NAME = "allaw-urist.ru"

$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }

Write-Host "=== Updating .env File ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "Checking current DATABASE_URL..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "grep DATABASE_URL $VPS_PROJECT_DIR/releases/current/.env"

Write-Host "`nUpdating DATABASE_URL..." -ForegroundColor Yellow
$newDbUrl = "postgres://allaw_user:allaw_temp_password_123@localhost:5432/allaw_urist"

# Use a more robust approach: grep -v to remove old line, then append new one
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "cd $VPS_PROJECT_DIR/releases/current && grep -v '^DATABASE_URL=' .env > .env.tmp && echo 'DATABASE_URL=$newDbUrl' >> .env.tmp && mv .env.tmp .env"

Write-Host "`nVerifying update..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "grep DATABASE_URL $VPS_PROJECT_DIR/releases/current/.env"

Write-Host "`n✓ .env updated" -ForegroundColor Green

Write-Host "`nRestarting application..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 restart $PROJECT_NAME"
Start-Sleep -Seconds 3

Write-Host "`nChecking logs for database connection..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 logs $PROJECT_NAME --lines 30 --nostream | grep -E 'DB|database|error|listening'"

Write-Host "`n=== Done ===" -ForegroundColor Cyan
