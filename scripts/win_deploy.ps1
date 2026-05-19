# deploy_and_status.ps1 — Deploy and manage Node.js app, BullMQ worker, and FastAPI microservice under Windows
# Requires: PowerShell 5+, node, npm, python, pip, psql (from postgresql-x64-17), redis-server (from Redis for Windows or WSL), jq (from Chocolatey or manual)
# Usage: .\deploy_and_status.ps1 [start [install|check|services]|stop|restart|status]
# Version: 1.1.1

# ------------------------------
# Configuration
# ------------------------------
$TMUX_SESSION = "voice-agent"
$PORT = if ($env:PORT) { $env:PORT } else { 3000 }
$DATABASE_URL = if ($env:DATABASE_URL) { $env:DATABASE_URL } else { "postgres://postgres:postgres@localhost:5432/db" }
$REDIS_URL = if ($env:REDIS_URL) { $env:REDIS_URL } else { "redis://localhost:6379" }
$PYTHON_VENV = "venv"
$FASTAPI_PORT = 4001
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Definition
$PROJECT_ROOT = Split-Path -Parent $SCRIPT_DIR
$PID_FILE = Join-Path $PROJECT_ROOT ".pids"

# ------------------------------
# Helpers
# ------------------------------
function Log { Write-Host -ForegroundColor Cyan "[$(Get-Date -Format HH:mm:ss)] $args" }
function Warn { Write-Host -ForegroundColor Yellow "[WARN] $args" }
function Err { Write-Host -ForegroundColor Red "[ERR] $args"; exit 1 }
function Check-Cmd { param ($cmd); if (!(Get-Command $cmd -ErrorAction SilentlyContinue)) { Warn "Missing command: $cmd"; return $false }; return $true }
function Handle-Error { param ($msg); Warn $msg; $choice = Read-Host "Continue anyway? (y/n)"; if ($choice -eq 'y' -or $choice -eq 'Y') { return } else { exit 1 } }

# ------------------------------
# Dependency Installation
# ------------------------------
function Install-Dependencies {
  Log "Installing system dependencies..."
  # Note: On Windows, assume manual install or use Chocolatey
  if (!(Check-Cmd 'choco')) { Warn "Chocolatey not found. Install it from https://chocolatey.org/install"; Handle-Error "Chocolatey required for auto-install" }
  choco install nodejs npm python postgresql-x64-17 redis jq --yes 2>$null
  if ($LASTEXITCODE -ne 0) { Handle-Error "Failed to install dependencies via Chocolatey" }
  # Start services manually if needed (postgresql-x64-17/Redis)
  Start-Service postgresql-x64-17 -ErrorAction SilentlyContinue
  if ($?) { Log "postgresql-x64-17 started" } else { Warn "Failed to start postgresql-x64-17"; Handle-Error "postgresql-x64-17 start issue" }
  Start-Service Redis -ErrorAction SilentlyContinue
  if ($?) { Log "Redis started" } else { Warn "Failed to start Redis"; Handle-Error "Redis start issue" }
  # Set Postgres password (manual step)
  Warn "Manually set Postgres password if needed: psql -U postgres -c `"ALTER USER postgres WITH PASSWORD 'postgres';`""
}

# ------------------------------
# Dependency Checks
# ------------------------------
function Check-Dependencies {
  Log "Checking dependencies..."
  $missing = 0
  if (!(Check-Cmd 'node')) { $missing++ }
  if (!(Check-Cmd 'npm')) { $missing++ }
  if (!(Check-Cmd 'python')) { $missing++ }
  if (!(Check-Cmd 'pip')) { $missing++ }
  if (!(Check-Cmd 'psql')) { $missing++ }
  if (!(Check-Cmd 'redis-server')) { $missing++ }
  if (!(Check-Cmd 'jq')) { $missing++ }
  if ($missing -eq 0) { Log "All dependencies are installed" } else { Handle-Error "Some dependencies are missing. Run 'Install-Dependencies'." }
}

# ------------------------------
# Environment Setup
# ------------------------------
function Setup-Environment {
  Log "Setting up environment..."
  $envFile = Join-Path $PROJECT_ROOT ".env"
  if (!(Test-Path $envFile)) {
    Log "Copying .env.example to .env..."
    $example = Join-Path $PROJECT_ROOT ".env.example"
    if (!(Test-Path $example)) { Handle-Error ".env.example not found" }
    Copy-Item $example $envFile
  }
  Get-Content $envFile | ForEach-Object { if ($_ -match '^([^#=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2]) } }
  if (!$env:OPENAI_API_KEY) { Handle-Error "Missing OPENAI_API_KEY in .env" }
  $env:MODEL_NAME = if ($env:MODEL_NAME) { $env:MODEL_NAME } else { "gpt-4o-realtime-preview-2024-12-17" }
  $env:VOICE_ID = if ($env:VOICE_ID) { $env:VOICE_ID } else { "ash" }
  if (!$env:ADMIN_API_KEY) { Handle-Error "Missing ADMIN_API_KEY in .env" }
  Log "Environment variables loaded"
}

# ------------------------------
# Database Setup
# ------------------------------
function Setup-Database {
  Log "Setting up postgresql-x64-17..."
  # Assume dbctl.ps1 or manual
  Warn "Run db setup manually on Windows (psql commands from dbctl.sh)"
  # Example: psql -Command "SELECT 1" -ConnectionString $DATABASE_URL
  if ($?) { Log "postgresql-x64-17 connection: OK" } else { Warn "postgresql-x64-17 connection: Failed" }
  Handle-Error "Database setup not automated for Windows yet"
}

# ------------------------------
# Python Virtual Environment Setup
# ------------------------------
function Setup-PythonVenv {
  Log "Setting up Python virtual environment..."
  $venvPath = Join-Path $PROJECT_ROOT $PYTHON_VENV
  if (!(Test-Path $venvPath)) { python -m venv $venvPath }
  if ($?) { Log "Venv created" } else { Handle-Error "Failed to create venv" }
  & (Join-Path $venvPath "Scripts\Activate.ps1")
  pip install -U pip wheel
  if ($?) { Log "Pip updated" } else { Handle-Error "Failed to update pip" }
  pip install fastapi uvicorn rapidfuzz faiss-cpu openai
  if ($?) { Log "Python deps installed" } else { Handle-Error "Failed to install Python dependencies" }
}

# ------------------------------
# Node.js Dependencies
# ------------------------------
function Setup-NodeDeps {
  Log "Installing Node.js dependencies..."
  npm ci --prefix $PROJECT_ROOT
  if ($?) { Log "Node deps installed" } else { Handle-Error "npm ci failed" }
}

# ------------------------------
# Start Services (use Start-Process instead of tmux)
# ------------------------------
function Start-Services {
  Log "Starting services..."
  $logsDir = Join-Path $PROJECT_ROOT "logs"
  New-Item -Path $logsDir -ItemType Directory -Force | Out-Null

  # Start Node.js server
  Start-Process -NoNewWindow -FilePath "node" -ArgumentList (Join-Path $PROJECT_ROOT "src\index.js") -RedirectStandardOutput (Join-Path $logsDir "node.log") -RedirectStandardError (Join-Path $logsDir "node.err")
  $nodePid = (Get-Process -Name "node" -ErrorAction SilentlyContinue | Select-Object -Last 1).Id

  # Start BullMQ worker
  Start-Process -NoNewWindow -FilePath "node" -ArgumentList (Join-Path $PROJECT_ROOT "embeddingsWorker.js") -RedirectStandardOutput (Join-Path $logsDir "worker.log") -RedirectStandardError (Join-Path $logsDir "worker.err")
  $workerPid = (Get-Process -Name "node" -ErrorAction SilentlyContinue | Select-Object -Last 1).Id

  # Start FastAPI (activate venv first)
  $fastapiCmd = "cd $PROJECT_ROOT\services\price-search; .\$PYTHON_VENV\Scripts\Activate.ps1; uvicorn main:app --host 0.0.0.0 --port $FASTAPI_PORT"
  Start-Process -NoNewWindow -FilePath "powershell" -ArgumentList "-Command $fastapiCmd" -RedirectStandardOutput (Join-Path $logsDir "fastapi.log") -RedirectStandardError (Join-Path $logsDir "fastapi.err")
  $fastapiPid = (Get-Process -Name "powershell" -ErrorAction SilentlyContinue | Select-Object -Last 1).Id

  # Save PIDs
  @"
node_server_pid=$nodePid
worker_pid=$workerPid
fastapi_pid=$fastapiPid
"@ | Out-File $PID_FILE

  Log "Waiting for services to start..."
  Start-Sleep -Seconds 5

  # Health checks
  try { Invoke-WebRequest "http://localhost:$PORT/api/health" -UseBasicParsing | Out-Null; Log "Node.js server healthy" } catch { Warn "Node.js server health check failed"; Get-Content (Join-Path $logsDir "node.log") }
  try { Invoke-WebRequest "http://localhost:$FASTAPI_PORT/health" -UseBasicParsing | Out-Null; Log "FastAPI microservice healthy" } catch { Warn "FastAPI health check failed"; Get-Content (Join-Path $logsDir "fastapi.log"); Handle-Error "FastAPI failed" }
}

# ------------------------------
# Stop Services
# ------------------------------
function Stop-Services {
  Log "Stopping services..."
  if (Test-Path $PID_FILE) {
    $pids = Get-Content $PID_FILE | ConvertFrom-StringData
    Stop-Process -Id $pids.node_server_pid -Force -ErrorAction SilentlyContinue
    Stop-Process -Id $pids.worker_pid -Force -ErrorAction SilentlyContinue
    Stop-Process -Id $pids.fastapi_pid -Force -ErrorAction SilentlyContinue
    Remove-Item $PID_FILE
    Log "Services stopped"
  } else {
    Warn "No PID file found"
  }
}

# ------------------------------
# Restart Services
# ----------------------
function Restart-Services {
  Log "Restarting services..."
  Stop-Services
  Start-Services
}

# ------------------------------
# Check Status
# ------------------------------
function Check-Status {
  Log "Checking service status..."
  if (Test-Path $PID_FILE) {
    $pids = Get-Content $PID_FILE | ConvertFrom-StringData
    Log "Node.js server PID: $($pids.node_server_pid -or 'unknown')"
    Log "BullMQ worker PID: $($pids.worker_pid -or 'unknown')"
    Log "FastAPI microservice PID: $($pids.fastapi_pid -or 'unknown')"
    try { Invoke-WebRequest "http://localhost:$PORT/api/health" -UseBasicParsing | Out-Null; Log "Node.js server: healthy" } catch { Warn "Node.js server: unhealthy" }
    try { Invoke-WebRequest "http://localhost:$FASTAPI_PORT/health" -UseBasicParsing | Out-Null; Log "FastAPI microservice: healthy" } catch { Warn "FastAPI microservice: unhealthy" }
  } else {
    Log "No services running (PID file missing)"
  }
}

# ------------------------------
# Check Environment and Database
# ------------------------------
function Check-Environment {
  Log "Checking environment and database..."
  Check-Dependencies
  Setup-Environment
  try { psql -Command "SELECT 1" -ConnectionString $DATABASE_URL | Out-Null; Log "postgresql-x64-17 connection: OK" } catch { Warn "postgresql-x64-17 connection: Failed" }
  $priceFile = Join-Path $PROJECT_ROOT "profnastil_price.json"
  if (Test-Path $priceFile) { Log "Price data file: Found" } else { Warn "Price data file: Not found" }
  try { Invoke-WebRequest "http://localhost:$PORT/api/health" -UseBasicParsing | Out-Null; Log "Node.js server: Running" } catch { Log "Node.js server: Not running" }
  try { Invoke-WebRequest "http://localhost:$FASTAPI_PORT/health" -UseBasicParsing | Out-Null; Log "FastAPI microservice: Running" } catch { Log "FastAPI microservice: Not running" }
}

# ------------------------------
# Usage
# ------------------------------
function Usage {
  Write-Host "Usage: $MyInvocation.MyCommandName [start [install|check|services]|stop|restart|status]"
  Write-Host "Version: 1.1.1"
  Write-Host "Commands:"
  Write-Host "  start                Run all actions (install, check, services)"
  Write-Host "  start install        Install system dependencies"
  Write-Host "  start check          Check environment and database setup"
  Write-Host "  start services       Start Node.js server, BullMQ worker, and FastAPI microservice (assumes setups done)"
  Write-Host "  stop                 Stop all services"
  Write-Host "  restart              Restart all services"
  Write-Host "  status               Check service status"
  Write-Host "Examples:"
  Write-Host "  $MyInvocation.MyCommandName start             # Run full deployment"
  Write-Host "  $MyInvocation.MyCommandName start install     # Install dependencies only"
  Write-Host "  $MyInvocation.MyCommandName start check       # Check environment and database"
  Write-Host "  $MyInvocation.MyCommandName start services    # Start services only"
  Write-Host "  $MyInvocation.MyCommandName stop              # Stop all services"
  Write-Host "  $MyInvocation.MyCommandName status            # Check service status"
}

# ------------------------------
# Main
# ------------------------------
# ------------------------------
# Main
# ------------------------------
$command = if ($args.Count -ge 1 -and $args[0]) { $args[0] } else { "start" }
$subcommand = if ($args.Count -ge 2 -and $args[1]) { $args[1] } else { "all" }

switch ($command) {
  "start" {
    switch ($subcommand) {
      "install"  { Install-Dependencies }
      "check"    { Check-Environment }
      "services" { Setup-Environment; Start-Services; Write-Host "Services started. Web-Agent: http://localhost:$PORT | Search API: http://localhost:$FASTAPI_PORT/health" }
      "all"      { Install-Dependencies; Check-Environment; Setup-Database; Setup-PythonVenv; Setup-NodeDeps; Start-Services; Write-Host "Full deployment complete. Web-Agent: http://localhost:$PORT | Search API: http://localhost:$FASTAPI_PORT/health" }
      default    { Usage; Handle-Error "Invalid subcommand for 'start'" }
    }
  }
  "stop"    { Stop-Services }
  "restart" { Restart-Services }
  "status"  { Check-Status }
  default   { Usage; Handle-Error "Invalid command" }
}