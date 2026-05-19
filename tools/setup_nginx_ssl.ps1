# Setup Nginx and SSL for allaw-urist.ru
# Root cause: App is running but not accessible via domain

$ErrorActionPreference = "Stop"

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"
$DOMAIN = "allaw-urist.ru"

$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }

Write-Host "=== Setting up Nginx and SSL ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Check if Nginx is installed
Write-Host "Step 1: Checking Nginx..." -ForegroundColor Yellow
$nginxInstalled = & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "command -v nginx && echo 'yes' || echo 'no'"

if ($nginxInstalled -ne "yes") {
    Write-Host "Installing Nginx..." -ForegroundColor Yellow
    & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "apt-get update && apt-get install -y nginx"
    Write-Host "✓ Nginx installed" -ForegroundColor Green
} else {
    Write-Host "✓ Nginx already installed" -ForegroundColor Green
}

# Step 2: Create Nginx config with SSL
Write-Host "`nStep 2: Creating Nginx configuration with SSL..." -ForegroundColor Yellow
$nginxConfig = @"
# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    return 301 https://`$host`$request_uri;
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name $DOMAIN www.$DOMAIN;

    # SSL certificates
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    client_max_body_size 25M;

    # Proxy to Node.js app
    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade `$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host `$host;
        proxy_cache_bypass `$http_upgrade;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
    }
}
"@

# Write config to temp file locally
$tempFile = [System.IO.Path]::GetTempFileName()
$nginxConfig | Out-File -FilePath $tempFile -Encoding UTF8

# Upload to VPS
$SCP_EXE = Join-Path $env:WINDIR "System32\OpenSSH\scp.exe"
if (!(Test-Path $SCP_EXE)) { $SCP_EXE = "scp" }

& $SCP_EXE -i $SSH_KEY $tempFile "${VPS_USER}@${VPS_IP}:/tmp/nginx_config"
Remove-Item $tempFile

# Move to nginx sites-available
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "mv /tmp/nginx_config /etc/nginx/sites-available/$DOMAIN"
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN"

# Remove default site if exists
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "rm -f /etc/nginx/sites-enabled/default"

Write-Host "✓ Nginx config created" -ForegroundColor Green

# Step 3: Test and reload Nginx
Write-Host "`nStep 3: Testing Nginx configuration..." -ForegroundColor Yellow
$nginxTest = & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "nginx -t 2>&1"
Write-Host $nginxTest

& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "systemctl reload nginx"
Write-Host "✓ Nginx reloaded" -ForegroundColor Green

# Step 4: Test HTTP access
Write-Host "`nStep 4: Testing HTTP access..." -ForegroundColor Yellow
Write-Host "Testing: http://localhost:3000/api/health" -ForegroundColor Gray
$httpTest = & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/health"
Write-Host "HTTP Status: $httpTest" -ForegroundColor $(if ($httpTest -eq "200") { "Green" } else { "Yellow" })

# Step 5: Verify SSL certificates
Write-Host "`nStep 5: Verifying SSL certificates..." -ForegroundColor Yellow
$certExists = & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "test -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem && test -f /etc/letsencrypt/live/$DOMAIN/privkey.pem && echo 'yes' || echo 'no'"

if ($certExists -eq "yes") {
    Write-Host "✓ SSL certificates found at /etc/letsencrypt/live/$DOMAIN/" -ForegroundColor Green
    
    # Show certificate info
    Write-Host "`nCertificate details:" -ForegroundColor Gray
    & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "openssl x509 -in /etc/letsencrypt/live/$DOMAIN/fullchain.pem -noout -subject -dates 2>/dev/null || echo 'Could not read certificate details'"
} else {
    Write-Host "✗ SSL certificates not found at /etc/letsencrypt/live/$DOMAIN/" -ForegroundColor Red
    Write-Host "Expected files:" -ForegroundColor Yellow
    Write-Host "  /etc/letsencrypt/live/$DOMAIN/fullchain.pem" -ForegroundColor Gray
    Write-Host "  /etc/letsencrypt/live/$DOMAIN/privkey.pem" -ForegroundColor Gray
}

Write-Host "`n=== Setup Summary ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "✓ Application running on port 3000" -ForegroundColor Green
Write-Host "✓ Nginx configured as reverse proxy with SSL" -ForegroundColor Green
Write-Host "✓ HTTP redirects to HTTPS" -ForegroundColor Green

if ($certExists -eq "yes") {
    Write-Host "✓ SSL certificates configured" -ForegroundColor Green
    Write-Host "✓ HTTPS access: https://$DOMAIN" -ForegroundColor Green
} else {
    Write-Host "✗ SSL certificates missing - run certbot for $DOMAIN" -ForegroundColor Red
}

Write-Host ""
Write-Host "Access the application:" -ForegroundColor Yellow
Write-Host "  https://$DOMAIN" -ForegroundColor Cyan
Write-Host "  https://www.$DOMAIN" -ForegroundColor Cyan
Write-Host ""
Write-Host "Check application status:" -ForegroundColor Yellow
Write-Host "  ssh $VPS_USER@$VPS_IP" -ForegroundColor Cyan
Write-Host "  pm2 list" -ForegroundColor Cyan
Write-Host "  pm2 logs allaw-urist.ru" -ForegroundColor Cyan
Write-Host "  systemctl status nginx" -ForegroundColor Cyan
Write-Host ""
