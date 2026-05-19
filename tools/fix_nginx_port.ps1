# Fix Nginx port mismatch
# Root cause: Old Nginx config points to port 3050, but app runs on port 3000

$ErrorActionPreference = "Stop"

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"
$DOMAIN = "allaw-urist.ru"

$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }

Write-Host "=== Fixing Nginx Port Configuration ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "Problem: Nginx is proxying to port 3050, but app runs on port 3000" -ForegroundColor Yellow
Write-Host ""

# Show current config
Write-Host "Current Nginx config:" -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "grep -n 'proxy_pass' /etc/nginx/sites-available/$DOMAIN || echo 'Config not found'"

Write-Host "`nUpdating Nginx config to use port 3000..." -ForegroundColor Yellow

# Fix the port in the config
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sed -i 's|http://127.0.0.1:3050|http://localhost:3000|g' /etc/nginx/sites-available/$DOMAIN"
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sed -i 's|http://localhost:3050|http://localhost:3000|g' /etc/nginx/sites-available/$DOMAIN"

Write-Host "✓ Config updated" -ForegroundColor Green

# Verify the change
Write-Host "`nVerifying update:" -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "grep -n 'proxy_pass' /etc/nginx/sites-available/$DOMAIN"

# Test Nginx config
Write-Host "`nTesting Nginx configuration..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "nginx -t"

# Reload Nginx
Write-Host "`nReloading Nginx..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "systemctl reload nginx"

Write-Host "✓ Nginx reloaded" -ForegroundColor Green

Write-Host "`n=== Fix Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "✓ Nginx now proxies to port 3000" -ForegroundColor Green
Write-Host ""
Write-Host "Test the application:" -ForegroundColor Yellow
Write-Host "  https://$DOMAIN" -ForegroundColor Cyan
Write-Host ""
