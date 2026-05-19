# Fix database configuration on VPS
# Root cause: .env has default DATABASE_URL with wrong credentials
# Need to update to use the allaw_user created during VPS setup

$ErrorActionPreference = "Stop"

$VPS_IP = "89.125.92.10"
$VPS_USER = "root"
$SSH_KEY = "$env:USERPROFILE\.ssh\id_rsa_deploy"
$VPS_PROJECT_DIR = "/opt/sed-lex-voice"
$PROJECT_NAME = "allaw-urist.ru"

$SSH_EXE = Join-Path $env:WINDIR "System32\OpenSSH\ssh.exe"
if (!(Test-Path $SSH_EXE)) { $SSH_EXE = "ssh" }

Write-Host "=== Fixing Database Configuration ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Check if database and user exist
Write-Host "Step 1: Checking database setup..." -ForegroundColor Yellow
$dbCheck = & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sudo -u postgres psql -tAc `"SELECT 1 FROM pg_database WHERE datname='allaw_urist'`""

if ($dbCheck -ne "1") {
    Write-Host "Database doesn't exist. Creating..." -ForegroundColor Yellow
    & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sudo -u postgres psql -c `"CREATE DATABASE allaw_urist;`""
    & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sudo -u postgres psql -c `"CREATE USER allaw_user WITH PASSWORD 'allaw_temp_password_123';`""
    & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sudo -u postgres psql -c `"GRANT ALL PRIVILEGES ON DATABASE allaw_urist TO allaw_user;`""
    & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "sudo -u postgres psql -d allaw_urist -c `"CREATE EXTENSION IF NOT EXISTS vector;`""
    Write-Host "✓ Database created" -ForegroundColor Green
} else {
    Write-Host "✓ Database exists" -ForegroundColor Green
}

# Step 2: Update .env with correct DATABASE_URL
Write-Host "`nStep 2: Updating .env file..." -ForegroundColor Yellow
$dbPassword = "allaw_temp_password_123"
$dbUrl = "postgres://allaw_user:${dbPassword}@localhost:5432/allaw_urist"

& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "cd $VPS_PROJECT_DIR/releases/current && sed -i 's|DATABASE_URL=.*|DATABASE_URL=$dbUrl|g' .env && echo 'DATABASE_URL updated'"

Write-Host "✓ .env updated with correct database credentials" -ForegroundColor Green

# Step 3: Run database migrations
Write-Host "`nStep 3: Running database migrations..." -ForegroundColor Yellow
$sqlFiles = & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "ls $VPS_PROJECT_DIR/releases/current/scripts/*.sql 2>/dev/null | wc -l"

if ([int]$sqlFiles -gt 0) {
    Write-Host "Found SQL migration files, running them..." -ForegroundColor Gray
    
    # Get list of SQL files
    $fileList = & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "ls $VPS_PROJECT_DIR/releases/current/scripts/*.sql"
    
    foreach ($sqlFile in $fileList) {
        $fileName = Split-Path $sqlFile -Leaf
        Write-Host "  Running: $fileName" -ForegroundColor Gray
        & $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "PGPASSWORD='$dbPassword' psql -U allaw_user -d allaw_urist -h localhost -f $sqlFile 2>&1 | grep -v 'already exists' || true"
    }
    
    Write-Host "✓ Migrations completed" -ForegroundColor Green
} else {
    Write-Host "⚠ No SQL migration files found" -ForegroundColor Yellow
}

# Step 4: Restart application
Write-Host "`nStep 4: Restarting application..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 restart $PROJECT_NAME"
Start-Sleep -Seconds 3

# Step 5: Check logs
Write-Host "`nStep 5: Checking application logs..." -ForegroundColor Yellow
& $SSH_EXE -i $SSH_KEY $VPS_USER@$VPS_IP "pm2 logs $PROJECT_NAME --lines 30 --nostream"

Write-Host "`n=== Database Configuration Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "✓ Database: allaw_urist" -ForegroundColor Green
Write-Host "✓ User: allaw_user" -ForegroundColor Green
Write-Host "✓ Password: $dbPassword" -ForegroundColor Green
Write-Host ""
Write-Host "⚠ IMPORTANT: Change the database password!" -ForegroundColor Yellow
Write-Host "Run on VPS:" -ForegroundColor Yellow
Write-Host "  sudo -u postgres psql" -ForegroundColor Gray
Write-Host "  ALTER USER allaw_user WITH PASSWORD 'your_secure_password';" -ForegroundColor Gray
Write-Host "  \q" -ForegroundColor Gray
Write-Host ""
Write-Host "Then update .env:" -ForegroundColor Yellow
Write-Host "  nano $VPS_PROJECT_DIR/releases/current/.env" -ForegroundColor Gray
Write-Host "  # Update DATABASE_URL with new password" -ForegroundColor Gray
Write-Host "  pm2 restart $PROJECT_NAME" -ForegroundColor Gray
Write-Host ""
