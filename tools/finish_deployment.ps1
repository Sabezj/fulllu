# Finish deployment from Step 7 onwards
# Root cause: Previous deployment failed at npm install due to line ending issues
# This script completes the remaining steps for the already-uploaded release

$ErrorActionPreference = "Stop"

# Configuration
$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"
$VPS_PROJECT_DIR = "/opt/sed-lex-voice"
$PROJECT_NAME = "allaw-urist.ru"
$DOMAIN = "allaw-urist.ru"

# Find the latest release directory
$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }

Write-Host "=== Finishing Deployment for $PROJECT_NAME ===" -ForegroundColor Cyan
Write-Host ""

# Get the latest release name
Write-Host "Finding latest release..." -ForegroundColor Yellow
$RELEASE_NAME = & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "cd $VPS_PROJECT_DIR/releases && ls -t | grep -E '^[0-9]{8}_[0-9]{6}$' | head -n 1"
$RELEASE_DIR = "$VPS_PROJECT_DIR/releases/$RELEASE_NAME"

Write-Host "✓ Found release: $RELEASE_NAME" -ForegroundColor Green
Write-Host ""

# Step 7: Install dependencies
Write-Host "Step 7: Installing dependencies..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "cd $RELEASE_DIR && npm install --no-optional"
Write-Host "✓ Dependencies installed" -ForegroundColor Green

# Step 7b: Build frontend
Write-Host "`nStep 7b: Building frontend..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "cd $RELEASE_DIR && export NODE_ENV=production && export DOMAIN=$DOMAIN && npm run build"
Write-Host "✓ Frontend built" -ForegroundColor Green

# Step 7c: Clean devDependencies
Write-Host "`nStep 7c: Cleaning devDependencies..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "cd $RELEASE_DIR && npm prune --production"
Write-Host "✓ DevDependencies removed" -ForegroundColor Green

# Step 8: Setup .env
Write-Host "`nStep 8: Setting up environment..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "cd $RELEASE_DIR && if [ ! -f .env ]; then cp .env.example .env && sed -i 's|NODE_ENV=development|NODE_ENV=production|g' .env && sed -i 's|ALLOWED_ORIGINS=.*|ALLOWED_ORIGINS=https://$DOMAIN,https://www.$DOMAIN,http://$DOMAIN,http://www.$DOMAIN|g' .env && sed -i 's|SSL_DOMAIN=.*|SSL_DOMAIN=$DOMAIN|g' .env && sed -i 's|ENABLE_HTTPS=false|ENABLE_HTTPS=true|g' .env && echo 'Created .env'; else echo '.env exists'; fi"
Write-Host "✓ Environment configured" -ForegroundColor Green

# Step 9: Update symlink
Write-Host "`nStep 9: Switching to new release..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "cd $VPS_PROJECT_DIR/releases && rm -f current && ln -s $RELEASE_NAME current"
Write-Host "✓ Symlink updated: current -> $RELEASE_NAME" -ForegroundColor Green

# Step 10: Setup PM2
Write-Host "`nStep 10: Configuring PM2..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "cd $VPS_PROJECT_DIR/releases/current && pm2 list | grep -q '$PROJECT_NAME' && pm2 delete $PROJECT_NAME || true"
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "cd $VPS_PROJECT_DIR/releases/current && pm2 start ecosystem.config.cjs --env production && pm2 save"
Write-Host "✓ PM2 configured and started" -ForegroundColor Green

# Step 11: Check Nginx
Write-Host "`nStep 11: Checking Nginx..." -ForegroundColor Yellow
$nginxExists = & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "test -f /etc/nginx/sites-available/$DOMAIN && echo 'yes' || echo 'no'"
if ($nginxExists -eq "yes") {
    Write-Host "✓ Nginx already configured" -ForegroundColor Green
} else {
    Write-Host "⚠ Nginx not configured - run full deployment or configure manually" -ForegroundColor Yellow
}

# Step 12: Check SSL
Write-Host "`nStep 12: Checking SSL..." -ForegroundColor Yellow
$sslExists = & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "test -d /etc/letsencrypt/live/$DOMAIN && echo 'yes' || echo 'no'"
if ($sslExists -eq "yes") {
    Write-Host "✓ SSL certificate exists" -ForegroundColor Green
} else {
    Write-Host "⚠ No SSL certificate - run: certbot --nginx -d $DOMAIN -d www.$DOMAIN" -ForegroundColor Yellow
}

# Verify
Write-Host "`n=== Verification ===" -ForegroundColor Cyan
Write-Host "`nCurrent release:" -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "ls -lh $VPS_PROJECT_DIR/releases/current"

Write-Host "`nPM2 status:" -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 list"

Write-Host "`nApplication logs (last 20 lines):" -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 logs $PROJECT_NAME --lines 20 --nostream"

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "✓ Release: $RELEASE_NAME" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. Configure .env secrets:"
Write-Host "   ssh $VPS_USER@$VPS_IP"
Write-Host "   nano $VPS_PROJECT_DIR/releases/current/.env"
Write-Host "   # Set: OPENAI_API_KEY, ADMIN_API_KEY, ADMIN_SESSION_SECRET, DATABASE_URL"
Write-Host "   pm2 restart $PROJECT_NAME"
Write-Host ""
Write-Host "2. Test the application:"
Write-Host "   http://$DOMAIN (or https:// if SSL is configured)"
Write-Host ""
