# Autonomous redeploy script for allaw-urist.ru
# Root cause: Need fully automated, non-interactive deployment handling all discovered issues:
# - Windows line endings in bash scripts
# - Database credentials and permissions
# - Nginx port mismatch (3050 vs 3000)
# - CORS configuration
# - Frontend build on server with correct domain
# - Admin secrets must come from the real deployment .env, not .env.example
# - LawVoice deploy must keep the legacy commerce catalog disabled

$ErrorActionPreference = "Stop"

# ============================================================================
# CONFIGURATION
# ============================================================================
$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"
$DEV_ROOT = "F:\GitHub\vangZ_strict_patched_plus_voice_assistant"
$ENV_SOURCE = "F:\.env"
$VPS_PROJECT_DIR = "/opt/sed-lex-voice"
$PROJECT_NAME = "allaw-urist.ru"
$DOMAIN = "allaw-urist.ru"

# SSH/SCP executables
$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
$SCP_EXE = Join-Path $env:WINDIR "System32\OpenSSH\scp.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }
if (!(Test-Path $SCP_EXE)) { $SCP_EXE = "scp" }
$SSH_OPTIONS = @(
    "-i", $SSH_KEY,
    "-o", "StrictHostKeyChecking=no",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=15",
    "-o", "ServerAliveInterval=15",
    "-o", "ServerAliveCountMax=4"
)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
function SSH-Exec {
    param([string]$Command)
    & $SSH_EXE @SSH_OPTIONS $VPS_USER@$VPS_IP $Command
}

function Log-Step {
    param([string]$Message, [string]$Color = "Yellow")
    Write-Host "`n$Message" -ForegroundColor $Color
}

function Log-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Log-Error {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Read-EnvFile {
    param([string]$Path)
    $result = @{}
    foreach ($line in Get-Content -Path $Path) {
        if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)\s*$') { continue }
        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $result[$key] = $value
    }
    return $result
}

function Set-RemoteEnvValue {
    param(
        [string]$ReleaseDir,
        [string]$Key,
        [string]$Value
    )
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Value))
    SSH-Exec "cd $ReleaseDir && value=`$(printf '%s' '$encoded' | base64 -d) && { grep -v '^$Key=' .env || true; } > .env.tmp && printf '%s=%s\n' '$Key' `"`$value`" >> .env.tmp && mv .env.tmp .env" | Out-Null
}

function SSH-ExecScript {
    param([string]$Script)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Script))
    SSH-Exec "printf '%s' '$encoded' | base64 -d | bash"
}

function Copy-DeploymentEntry {
    param(
        [string]$SourceRoot,
        [string]$TempRoot,
        [string]$RelativePath
    )

    $sourcePath = Join-Path $SourceRoot $RelativePath
    if (!(Test-Path $sourcePath)) {
        return
    }

    $destinationPath = Join-Path $TempRoot $RelativePath
    $parentDir = Split-Path -Parent $destinationPath
    if ($parentDir -and !(Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    Copy-Item -Path $sourcePath -Destination $destinationPath -Recurse -Force
}

# ============================================================================
# MAIN DEPLOYMENT SCRIPT
# ============================================================================
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Autonomous Redeploy: $PROJECT_NAME" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "VPS: $VPS_USER@$VPS_IP"
Write-Host "Dev Root: $DEV_ROOT"
Write-Host "Env Source: $ENV_SOURCE"
Write-Host "Domain: $DOMAIN"
Write-Host ""

# ----------------------------------------------------------------------------
# STEP 1: Verify prerequisites
# ----------------------------------------------------------------------------
Log-Step "Step 1: Verifying prerequisites..."

if (!(Test-Path $DEV_ROOT)) {
    Log-Error "Dev root not found: $DEV_ROOT"
    exit 1
}

if (!(Test-Path $SSH_KEY)) {
    Log-Error "SSH key not found: $SSH_KEY"
    exit 1
}

if (!(Test-Path $ENV_SOURCE)) {
    Log-Error "Deployment env not found: $ENV_SOURCE"
    exit 1
}

$deployEnv = Read-EnvFile $ENV_SOURCE
foreach ($requiredKey in @("OPENAI_API_KEY", "ADMIN_API_KEY", "DATABASE_URL")) {
    if (-not $deployEnv.ContainsKey($requiredKey) -or [string]::IsNullOrWhiteSpace($deployEnv[$requiredKey])) {
        Log-Error "Required key missing in ${ENV_SOURCE}: $requiredKey"
        exit 1
    }
}
Log-Success "Deployment env verified; required keys are present"

# Test SSH connection
try {
    $test = SSH-Exec "echo 'OK'"
    if ($test -ne "OK") { throw "SSH test failed" }
    Log-Success "SSH connection verified"
} catch {
    Log-Error "SSH connection failed: $_"
    exit 1
}

# ----------------------------------------------------------------------------
# STEP 2: Create deployment package
# ----------------------------------------------------------------------------
Log-Step "Step 2: Creating deployment package..."

$TEMP_DIR = Join-Path $env:TEMP "allaw-urist-deploy-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null

# Files to copy
$pathsToCopy = @(
    'public',
    'profiles',
    'services',
    'src',
    'scripts',
    'ops',
    '__tests__',
    'docs',
    'server.js',
    'embeddingsWorker.js',
    'config.js',
    'package.json',
    'package-lock.json',
    'ecosystem.config.cjs',
    'webpack.config.cjs',
    'webpack.cpnfig.js',
    'jest.config.js',
    '.env.example',
    '.dockerignore',
    'Dockerfile',
    'README.md',
    'profnastil_price.json'
)

foreach ($relativePath in $pathsToCopy) {
    Copy-DeploymentEntry -SourceRoot $DEV_ROOT -TempRoot $TEMP_DIR -RelativePath $relativePath
}

Copy-Item -Path $ENV_SOURCE -Destination (Join-Path $TEMP_DIR ".env") -Force

Log-Success "Deployment package created"

# ----------------------------------------------------------------------------
# STEP 3: Backup current release
# ----------------------------------------------------------------------------
Log-Step "Step 3: Creating backup on VPS..."

$BACKUP_NAME = "backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
SSH-Exec "if [ -d $VPS_PROJECT_DIR/releases/current ]; then mkdir -p $VPS_PROJECT_DIR/backups && cp -r $VPS_PROJECT_DIR/releases/current $VPS_PROJECT_DIR/backups/$BACKUP_NAME && echo 'Backup created'; fi" | Out-Null
Log-Success "Backup: $BACKUP_NAME"

# ----------------------------------------------------------------------------
# STEP 4: Upload new release
# ----------------------------------------------------------------------------
Log-Step "Step 4: Uploading new release..."

$RELEASE_NAME = Get-Date -Format 'yyyyMMdd_HHmmss'
$RELEASE_DIR = "$VPS_PROJECT_DIR/releases/$RELEASE_NAME"

SSH-Exec "mkdir -p $RELEASE_DIR"

# Upload files
if (Get-Command rsync -ErrorAction SilentlyContinue) {
    rsync -avz --progress -e "`"$SSH_EXE`" -i `"$SSH_KEY`" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4" "$TEMP_DIR/" "${VPS_USER}@${VPS_IP}:$RELEASE_DIR/"
} else {
    & $SCP_EXE @SSH_OPTIONS -r (Join-Path $TEMP_DIR ".") "${VPS_USER}@${VPS_IP}:$RELEASE_DIR/"
}

Remove-Item -Path $TEMP_DIR -Recurse -Force
Log-Success "Files uploaded to $RELEASE_NAME"

# ----------------------------------------------------------------------------
# STEP 5: Install dependencies and build
# ----------------------------------------------------------------------------
Log-Step "Step 5: Installing dependencies..."
SSH-Exec "cd $RELEASE_DIR && npm install --no-optional" | Out-Null
Log-Success "Dependencies installed"

Log-Step "Step 6: Building frontend on VPS..."
SSH-Exec "cd $RELEASE_DIR && export NODE_ENV=production && export DOMAIN=$DOMAIN && npm run build" | Out-Null
Log-Success "Frontend built with production domain"

Log-Step "Step 7: Cleaning devDependencies..."
SSH-Exec "cd $RELEASE_DIR && npm prune --production" | Out-Null
Log-Success "DevDependencies removed"

# ----------------------------------------------------------------------------
# STEP 8: Configure environment
# ----------------------------------------------------------------------------
Log-Step "Step 8: Configuring environment..."

$allowedOrigins = "https://$DOMAIN,https://www.$DOMAIN,http://$DOMAIN,http://www.$DOMAIN"

$envExists = (SSH-Exec "test -f $RELEASE_DIR/.env && echo 'yes' || echo 'no'").Trim()
if ($envExists -ne "yes") {
    Log-Error "Uploaded .env missing from release; refusing to deploy placeholders"
    exit 1
}

# Update critical settings
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "NODE_ENV" -Value "production"
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "DATABASE_URL" -Value $deployEnv["DATABASE_URL"]
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "ALLOWED_ORIGINS" -Value $allowedOrigins
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "SSL_DOMAIN" -Value $DOMAIN
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "ENABLE_HTTPS" -Value "false"
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "DEV_NO_AUTH" -Value "false"
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "ENABLE_COMMERCE_CATALOG" -Value "false"
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "USE_PY_SEARCH" -Value "false"
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "GRAFANA_ROOT_URL" -Value "https://$DOMAIN/grafana/"
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "PROMETHEUS_ROOT_URL" -Value "https://$DOMAIN/proteus/"
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "PROTEUS_ROOT_URL" -Value "https://$DOMAIN/proteus/"
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "GRAFANA_LOG_FILE" -Value "$RELEASE_DIR/logs/grafana.log"
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "PROMETHEUS_LOG_FILE" -Value "$RELEASE_DIR/logs/prometheus.log"
Set-RemoteEnvValue -ReleaseDir $RELEASE_DIR -Key "PROTEUS_LOG_FILE" -Value "$RELEASE_DIR/logs/prometheus.log"

Log-Success "Environment configured"

# ----------------------------------------------------------------------------
# STEP 9: Leave database unchanged
# ----------------------------------------------------------------------------
Log-Step "Step 9: Leaving database unchanged..."
Log-Success "Skipped PostgreSQL create/user/grant/extension/migration steps by request"

# ----------------------------------------------------------------------------
# STEP 10: Update symlink
# ----------------------------------------------------------------------------
Log-Step "Step 10: Switching to new release..."
SSH-Exec "cd $VPS_PROJECT_DIR/releases && rm -f current && ln -s $RELEASE_NAME current"
Log-Success "Symlink updated: current -> $RELEASE_NAME"

# ----------------------------------------------------------------------------
# STEP 11: Configure PM2
# ----------------------------------------------------------------------------
Log-Step "Step 11: Configuring PM2..."

$pm2Running = SSH-Exec "pm2 list | grep -q '$PROJECT_NAME' && echo 'yes' || echo 'no'"
if ($pm2Running -eq "yes") {
    SSH-Exec "pm2 delete $PROJECT_NAME" | Out-Null
}

SSH-Exec "cd $VPS_PROJECT_DIR/releases/current && pm2 start ecosystem.config.cjs --env production" | Out-Null
SSH-Exec "pm2 save" | Out-Null
Log-Success "PM2 configured and started"

Start-Sleep -Seconds 3

# ----------------------------------------------------------------------------
# STEP 12: Configure observability stack
# ----------------------------------------------------------------------------
Log-Step "Step 12: Configuring Prometheus/Grafana observability..."

$observabilityScript = @"
set -euo pipefail
cd "$RELEASE_DIR"
mkdir -p logs

if ! command -v docker >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
  systemctl enable --now docker
fi

if ! docker compose version >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
fi

docker compose -f ops/deploy/allaw-observability/docker-compose.yml up -d
docker ps --format '{{.Names}} {{.Status}}' | grep -E 'lawvoice-(prometheus|grafana|alertmanager)'
"@
SSH-ExecScript $observabilityScript | Out-Null
Log-Success "Prometheus/Grafana stack configured"

# ----------------------------------------------------------------------------
# STEP 13: Configure Nginx
# ----------------------------------------------------------------------------
Log-Step "Step 13: Configuring Nginx..."

# Check if Nginx config exists
$nginxExists = SSH-Exec "test -f /etc/nginx/sites-available/$DOMAIN && echo 'yes' || echo 'no'"

if ($nginxExists -eq "yes") {
    # Fix port if needed (3050 -> 3000)
    SSH-Exec "sed -i 's|http://127.0.0.1:3050|http://localhost:3000|g' /etc/nginx/sites-available/$DOMAIN" | Out-Null
    SSH-Exec "sed -i 's|http://localhost:3050|http://localhost:3000|g' /etc/nginx/sites-available/$DOMAIN" | Out-Null
    Log-Success "Nginx config updated"
} else {
    # Create new Nginx config
    $nginxConfig = @"
server {
    listen 80;
    server_name $DOMAIN www.$DOMAIN;
    return 301 https://`$host`$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN www.$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    include /etc/nginx/snippets/lawvoice-observability.conf;

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
    
    $tempFile = [System.IO.Path]::GetTempFileName()
    $nginxConfig | Out-File -FilePath $tempFile -Encoding UTF8
    & $SCP_EXE @SSH_OPTIONS $tempFile "${VPS_USER}@${VPS_IP}:/tmp/nginx_config"
    Remove-Item $tempFile
    
    SSH-Exec "mv /tmp/nginx_config /etc/nginx/sites-available/$DOMAIN" | Out-Null
    SSH-Exec "ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN" | Out-Null
    SSH-Exec "rm -f /etc/nginx/sites-enabled/default" | Out-Null
    Log-Success "Nginx config created"
}

$nginxObservabilityScriptTemplate = @'
set -euo pipefail
snippet="/etc/nginx/snippets/lawvoice-observability.conf"
site="/etc/nginx/sites-available/__DOMAIN__"
mkdir -p /etc/nginx/snippets
cp "__RELEASE_DIR__/ops/deploy/allaw-observability/nginx-allaw-observability.conf" "$snippet"

if ! grep -q 'lawvoice-observability.conf' "$site"; then
  python3 - "$site" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
include = "    include /etc/nginx/snippets/lawvoice-observability.conf;\n"
if include.strip() in text:
    raise SystemExit(0)

if "    client_max_body_size 25M;\n" in text:
    text = text.replace(
        "    client_max_body_size 25M;\n",
        "    client_max_body_size 25M;\n\n" + include,
        1,
    )
elif "    location / {\n" in text:
    text = text.replace("    location / {\n", include + "\n    location / {\n", 1)
else:
    raise SystemExit("Cannot find insertion point for observability nginx include")

path.write_text(text)
PY
fi
'@
$nginxObservabilityScript = $nginxObservabilityScriptTemplate.
    Replace("__RELEASE_DIR__", $RELEASE_DIR).
    Replace("__DOMAIN__", $DOMAIN)
SSH-ExecScript $nginxObservabilityScript | Out-Null

# Test and reload Nginx
$nginxTest = SSH-Exec "nginx -t 2>&1"
if ($nginxTest -match "successful") {
    SSH-Exec "systemctl reload nginx" | Out-Null
    Log-Success "Nginx reloaded"
} else {
    Log-Error "Nginx config test failed"
    Write-Host $nginxTest
}

# ----------------------------------------------------------------------------
# STEP 14: Verify deployment
# ----------------------------------------------------------------------------
Log-Step "Step 14: Verifying deployment..."

Start-Sleep -Seconds 2

# Check PM2 status
$pm2Status = SSH-Exec "pm2 list | grep '$PROJECT_NAME' | grep 'online' && echo 'online' || echo 'offline'"
if ($pm2Status -match "online") {
    Log-Success "Application is running"
} else {
    Log-Error "Application is not running"
    SSH-Exec "pm2 logs $PROJECT_NAME --lines 20 --nostream"
}

# Check port 3000
$portCheck = SSH-Exec "netstat -tlnp | grep :3000 && echo 'listening' || echo 'not listening'"
if ($portCheck -match "listening") {
    Log-Success "Port 3000 is listening"
} else {
    Log-Error "Port 3000 is not listening"
}

# Test HTTP response
$httpStatus = SSH-Exec "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/health"
if ($httpStatus -match "200|204") {
    Log-Success "HTTP response: $httpStatus"
} else {
    Log-Error "HTTP response: $httpStatus"
}

$publicHttpsStatus = SSH-Exec "curl -k -s -o /dev/null -w '%{http_code}' https://$DOMAIN/api/health || true"
if ($publicHttpsStatus -match "200|204") {
    Log-Success "Public HTTPS response ($DOMAIN): $publicHttpsStatus"
} else {
    Log-Error "Public HTTPS response ($DOMAIN): $publicHttpsStatus"
}

$publicWwwHttpsStatus = SSH-Exec "curl -k -s -o /dev/null -w '%{http_code}' https://www.$DOMAIN/api/health || true"
if ($publicWwwHttpsStatus -match "200|204") {
    Log-Success "Public HTTPS response (www.$DOMAIN): $publicWwwHttpsStatus"
} else {
    Log-Error "Public HTTPS response (www.$DOMAIN): $publicWwwHttpsStatus"
}

$grafanaStatus = SSH-Exec "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3001/grafana/login || true"
if ($grafanaStatus -match "200|302") {
    Log-Success "Grafana local response: $grafanaStatus"
} else {
    Log-Error "Grafana local response: $grafanaStatus"
}

$prometheusTargets = SSH-Exec "curl -fsS http://127.0.0.1:9090/api/v1/targets 2>/dev/null | grep -q 'lawvoice-web' && echo 'ok' || echo 'missing'"
if ($prometheusTargets -match "ok") {
    Log-Success "Prometheus has LawVoice scrape target"
} else {
    Log-Error "Prometheus LawVoice scrape target is missing"
}

# ============================================================================
# DEPLOYMENT SUMMARY
# ============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Deployment Complete" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Release: $RELEASE_NAME" -ForegroundColor Green
Write-Host "Backup: $BACKUP_NAME" -ForegroundColor Green
Write-Host ""
Write-Host "Application URL:" -ForegroundColor Yellow
Write-Host "  https://$DOMAIN" -ForegroundColor Cyan
Write-Host "  https://www.$DOMAIN" -ForegroundColor Cyan
Write-Host ""
Write-Host "Management Commands:" -ForegroundColor Yellow
Write-Host "  pm2 list                    # View processes" -ForegroundColor Gray
Write-Host "  pm2 logs $PROJECT_NAME      # View logs" -ForegroundColor Gray
Write-Host "  pm2 restart $PROJECT_NAME   # Restart app" -ForegroundColor Gray
Write-Host "  docker compose -f $VPS_PROJECT_DIR/releases/current/ops/deploy/allaw-observability/docker-compose.yml ps" -ForegroundColor Gray
Write-Host ""
Write-Host "Rollback Command:" -ForegroundColor Yellow
Write-Host "  cd $VPS_PROJECT_DIR/releases" -ForegroundColor Gray
Write-Host "  rm current && ln -s ../backups/$BACKUP_NAME current" -ForegroundColor Gray
Write-Host "  pm2 restart $PROJECT_NAME" -ForegroundColor Gray
Write-Host ""
Write-Host "Environment:" -ForegroundColor Yellow
Write-Host "  - Deployment .env was sourced from $ENV_SOURCE" -ForegroundColor Gray
Write-Host "  - DEV_NO_AUTH=false" -ForegroundColor Gray
Write-Host "  - ENABLE_COMMERCE_CATALOG=false" -ForegroundColor Gray
Write-Host "  - USE_PY_SEARCH=false" -ForegroundColor Gray
Write-Host "  - Grafana: https://$DOMAIN/grafana/" -ForegroundColor Gray
Write-Host "  - Proteus/Prometheus: https://$DOMAIN/proteus/" -ForegroundColor Gray
Write-Host "  - DATABASE_URL password was not printed" -ForegroundColor Gray
Write-Host ""
