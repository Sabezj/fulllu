# Copy missing files to VPS
# Root cause: profnastil_price.json wasn't included in deployment package

$ErrorActionPreference = "Stop"

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"
$DEV_ROOT = "F:\GitHub\vangZ_strict_patched_plus_voice_assistant"
$VPS_PROJECT_DIR = "/opt/sed-lex-voice"
$PROJECT_NAME = "allaw-urist.ru"

$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
$SCP_EXE = Join-Path $env:WINDIR "System32\OpenSSH\scp.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }
if (!(Test-Path $SCP_EXE)) { $SCP_EXE = "scp" }

Write-Host "=== Copying Missing Files ===" -ForegroundColor Cyan
Write-Host ""

# Get current release
$RELEASE_NAME = & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "cd $VPS_PROJECT_DIR/releases && ls -t | grep -E '^[0-9]{8}_[0-9]{6}$' | head -n 1"
$RELEASE_DIR = "$VPS_PROJECT_DIR/releases/$RELEASE_NAME"

Write-Host "Target release: $RELEASE_NAME" -ForegroundColor Yellow
Write-Host ""

# Check and copy profnastil_price.json
$localFile = Join-Path $DEV_ROOT "profnastil_price.json"
if (Test-Path $localFile) {
    Write-Host "Copying profnastil_price.json..." -ForegroundColor Yellow
    & $SCP_EXE -i $SSH_KEY $localFile "${VPS_USER}@${VPS_IP}:$RELEASE_DIR/"
    Write-Host "✓ Copied profnastil_price.json" -ForegroundColor Green
} else {
    Write-Host "⚠ profnastil_price.json not found locally, creating empty file..." -ForegroundColor Yellow
    & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "echo '[]' > $RELEASE_DIR/profnastil_price.json"
    Write-Host "✓ Created empty profnastil_price.json" -ForegroundColor Green
}

# Restart app
Write-Host "`nRestarting application..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 restart $PROJECT_NAME"
Start-Sleep -Seconds 3

Write-Host "`nChecking logs..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 logs $PROJECT_NAME --lines 30 --nostream"

Write-Host "`n=== Done ===" -ForegroundColor Cyan
