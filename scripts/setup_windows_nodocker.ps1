setup_windows_nodocker.ps1<#
Развёртывание без Docker
Требуется:
  • Node 18+   (winget install OpenJS.NodeJS.LTS)
  • Python 3.11 (winget install Python.Python.3.11)
  • PostgreSQL 16+ (https://postgresql.org/download/windows/)
#>

$ErrorActionPreference = "Stop"

function Test-Cmd($cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "❌  $cmd not found in PATH"
    }
}

Write-Host "🔍  Checking prerequisites…"
Test-Cmd "node"
Test-Cmd "npm"
Test-Cmd "python"
Test-Cmd "psql"

$env:PG_URI = $env:PG_URI -or "postgres://postgres:postgres@localhost:5432"

# 1. DB init
Write-Host "🗄️  Configuring Postgres…" -F Yellow
psql "$env:PG_URI/postgres" -c "SELECT 1" | Out-Null
psql "$env:PG_URI/postgres" -c "CREATE DATABASE products" -v ON_ERROR_STOP=0 | Out-Null
psql "$env:PG_URI/products" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm"
psql "$env:PG_URI/products" -c "CREATE EXTENSION IF NOT EXISTS vector"
psql "$env:PG_URI/products" -f "sql/01_init.sql"

# 2. Price import (uses node script -> easier on Windows)
Write-Host "📦  Importing price list…" -F Yellow
node services/price-search/scripts/load_prices_to_pg.js profnastil_price.json

# 3. venv + pip
Write-Host "🐍  Creating venv…" -F Yellow
python -m venv venv
.\venv\Scripts\python -m pip install --upgrade pip wheel
.\venv\Scripts\pip install -r services/price-search/requirements.txt

# 4. npm deps
Write-Host "📦  npm ci…" -F Yellow
npm ci

# 5. Launch two terminals (Windows Terminal / PS)
$api = "wt -w 0 nt --title SearchAPI --profile \"PowerShell\" --command \"cmd /c `\"venv\\Scripts\\activate && uvicorn services.price-search.main:app --port 4001`\"\""
$web = "wt -w 0 nt --title VoiceAgent --profile \"PowerShell\" --command \"cmd /c npm start\""
Invoke-Expression $api
Invoke-Expression $web

Write-Host "`n✅  Running!
 • http://localhost:4001/health
 • http://localhost:3000`n"

