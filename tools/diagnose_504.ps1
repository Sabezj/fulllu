# Diagnose 504 Gateway Timeout
# Root cause: Nginx can't connect to Node.js app on port 3000

$ErrorActionPreference = "Stop"

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"
$PROJECT_NAME = "allaw-urist.ru"

$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }

Write-Host "=== Diagnosing 504 Error ===" -ForegroundColor Cyan
Write-Host ""

# Check 1: Is PM2 running?
Write-Host "Check 1: PM2 process status" -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 list"

# Check 2: Is app listening on port 3000?
Write-Host "`nCheck 2: Port 3000 status" -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "netstat -tlnp | grep :3000 || echo 'Port 3000 not listening'"

# Check 3: Can we curl localhost:3000?
Write-Host "`nCheck 3: Testing localhost:3000" -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "curl -s -o /dev/null -w 'HTTP Status: %{http_code}\n' http://localhost:3000 || echo 'Connection failed'"

# Check 4: Recent app logs
Write-Host "`nCheck 4: Recent application logs" -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 logs $PROJECT_NAME --lines 50 --nostream"

# Check 5: Nginx error log
Write-Host "`nCheck 5: Nginx error log" -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "tail -n 20 /var/log/nginx/error.log"

Write-Host "`n=== Diagnosis Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Common fixes:" -ForegroundColor Yellow
Write-Host "1. If PM2 shows 'errored' or 'stopped':" -ForegroundColor Gray
Write-Host "   pm2 restart $PROJECT_NAME" -ForegroundColor Cyan
Write-Host ""
Write-Host "2. If port 3000 not listening:" -ForegroundColor Gray
Write-Host "   Check .env file has correct settings" -ForegroundColor Cyan
Write-Host "   pm2 logs $PROJECT_NAME" -ForegroundColor Cyan
Write-Host ""
Write-Host "3. If app crashes on startup:" -ForegroundColor Gray
Write-Host "   Check DATABASE_URL, OPENAI_API_KEY in .env" -ForegroundColor Cyan
Write-Host ""
