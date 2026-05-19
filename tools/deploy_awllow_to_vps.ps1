# Deploy awllow-uristv project to VPS
# Root cause: Need to redeploy project while preserving other VPS projects

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"
$LOCAL_PROJECT = "F:\GitHub\allow\awllow-urist\opt\sed-lex-voice\releases\20260310_122657"
$VPS_PROJECT_DIR = "/opt/sed-lex-voice"
$PROJECT_NAME = "allaw-urist.ru"

$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
$SCP_EXE = Join-Path $env:WINDIR "System32\OpenSSH\scp.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }
if (!(Test-Path $SCP_EXE)) { $SCP_EXE = "scp" }

Write-Host "=== Deploying $PROJECT_NAME to VPS ===" -ForegroundColor Cyan
Write-Host "VPS: $VPS_IP"
Write-Host "Local: $LOCAL_PROJECT"
Write-Host ""

# Check SSH connection
Write-Host "Step 1: Checking SSH connection..." -ForegroundColor Yellow
try {
    $test = & $SSH_EXE -i $SSH_KEY -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP "echo 'OK'"
    if ($test -ne "OK") {
        throw "SSH connection failed"
    }
    Write-Host "OK: SSH connection" -ForegroundColor Green
} catch {
    Write-Host "ERR: SSH connection failed: $_" -ForegroundColor Red
    exit 1
}

# Create backup of current version on VPS
Write-Host "`nStep 2: Creating backup on VPS..." -ForegroundColor Yellow
$BACKUP_NAME = "backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$backupScript = @"
if [ -d $VPS_PROJECT_DIR/current ]; then
    mkdir -p $VPS_PROJECT_DIR/backups
    cp -r $VPS_PROJECT_DIR/current $VPS_PROJECT_DIR/backups/$BACKUP_NAME
    echo 'OK: Backup created: $VPS_PROJECT_DIR/backups/$BACKUP_NAME'
else
    echo 'WARN: No current version to backup'
fi
"@
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP $backupScript

# Create release directory
Write-Host "`nStep 3: Preparing release directory..." -ForegroundColor Yellow
$RELEASE_NAME = Get-Date -Format 'yyyyMMdd_HHmmss'
$releaseDirScript = @"
mkdir -p $VPS_PROJECT_DIR/releases/$RELEASE_NAME
echo 'OK: Created: $VPS_PROJECT_DIR/releases/$RELEASE_NAME'
"@
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP $releaseDirScript

# Upload project files
Write-Host "`nStep 4: Uploading project files..." -ForegroundColor Yellow
Write-Host "This may take a few minutes..."

# Use rsync for efficient transfer
$rsyncCmd = "rsync -avz --progress -e 'ssh -i $SSH_KEY' --exclude 'node_modules' --exclude '.git' '$LOCAL_PROJECT/' ${VPS_USER}@${VPS_IP}:$VPS_PROJECT_DIR/releases/$RELEASE_NAME/"
Write-Host "Running: $rsyncCmd" -ForegroundColor Gray

if (Get-Command rsync -ErrorAction SilentlyContinue) {
    Invoke-Expression $rsyncCmd
} else {
    # Fallback to scp if rsync not available
    Write-Host "WARN: rsync not found, using scp (slower)" -ForegroundColor Yellow
    & $SCP_EXE -i $SSH_KEY -r "$LOCAL_PROJECT/*" "${VPS_USER}@${VPS_IP}:$VPS_PROJECT_DIR/releases/$RELEASE_NAME/"
}

Write-Host "OK: Files uploaded" -ForegroundColor Green

# Install dependencies on VPS
Write-Host "`nStep 5: Installing dependencies..." -ForegroundColor Yellow
$installDepsScript = @"
cd $VPS_PROJECT_DIR/releases/$RELEASE_NAME
if [ -f package.json ]; then
    npm install --production
    echo 'OK: Dependencies installed'
else
    echo 'WARN: No package.json found'
fi
"@
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP $installDepsScript

# Update symlink to new release
Write-Host "`nStep 6: Switching to new release..." -ForegroundColor Yellow
$switchScript = @"
cd $VPS_PROJECT_DIR
rm -f current
ln -s releases/$RELEASE_NAME current
echo 'OK: Symlink updated: current -> releases/$RELEASE_NAME'
"@
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP $switchScript

# Restart services
Write-Host "`nStep 7: Restarting services..." -ForegroundColor Yellow
$restartScript = @"
# Check if PM2 is managing the app
if pm2 list | grep -q \"$PROJECT_NAME\"; then
    pm2 restart $PROJECT_NAME
    echo 'OK: PM2 service restarted'
elif systemctl list-units | grep -q \"$PROJECT_NAME\"; then
    systemctl restart $PROJECT_NAME
    echo 'OK: Systemd service restarted'
else
    echo 'WARN: No service found to restart'
    echo 'You may need to start the service manually'
fi
"@
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP $restartScript

# Verify deployment
Write-Host "`nStep 8: Verifying deployment..." -ForegroundColor Yellow
$verifyScript = @"
echo '=== Deployment Status ==='
echo 'Current release:'
ls -la $VPS_PROJECT_DIR/current
echo ''
echo 'Available releases:'
ls -la $VPS_PROJECT_DIR/releases/
echo ''
echo 'Backups:'
ls -la $VPS_PROJECT_DIR/backups/ 2>/dev/null || echo 'No backups'
"@
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP $verifyScript

Write-Host "`n=== Deployment Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Release: $RELEASE_NAME"
Write-Host "Backup: $BACKUP_NAME"
Write-Host ""
Write-Host "To rollback:" -ForegroundColor Yellow
Write-Host "  ssh root@$VPS_IP"
Write-Host "  cd $VPS_PROJECT_DIR"
Write-Host "  rm current"
Write-Host "  ln -s backups/$BACKUP_NAME current"
Write-Host "  pm2 restart $PROJECT_NAME"
