# Fix database permissions for allaw_user
# Root cause: PostgreSQL 15+ changed default public schema permissions
# allaw_user needs explicit GRANT on schema public

$ErrorActionPreference = "Stop"

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"
$PROJECT_NAME = "allaw-urist.ru"

$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }

Write-Host "=== Fixing Database Permissions ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "Granting permissions to allaw_user..." -ForegroundColor Yellow

# Grant all necessary permissions
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sudo -u postgres psql -d allaw_urist -c `"GRANT ALL ON SCHEMA public TO allaw_user;`""
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sudo -u postgres psql -d allaw_urist -c `"GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO allaw_user;`""
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sudo -u postgres psql -d allaw_urist -c `"GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO allaw_user;`""
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sudo -u postgres psql -d allaw_urist -c `"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO allaw_user;`""
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sudo -u postgres psql -d allaw_urist -c `"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO allaw_user;`""

Write-Host "✓ Permissions granted" -ForegroundColor Green

Write-Host "`nRestarting application..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 restart $PROJECT_NAME"
Start-Sleep -Seconds 3

Write-Host "`nChecking logs..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 logs $PROJECT_NAME --lines 30 --nostream"

Write-Host "`n=== Done ===" -ForegroundColor Cyan
