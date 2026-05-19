<#
.SYNOPSIS
    Развёртывает проект «Voice Agent + Price Search» под Windows 10/11
    (требуется Docker Desktop с включённым WSL 2 backend).
#>

$ErrorActionPreference = "Stop"

function Test-Cmd($cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "❌  $cmd не найден. Установите Docker Desktop (вкл. WSL backend)."
    }
}

# 1. Проверка Docker
Test-Cmd "docker"
Test-Cmd "docker compose"

# 2. .env
if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Host "✅  .env создан из .env.example"
}

# 3. Build + Up
Write-Host "🔧  Собираем образы…" -ForegroundColor Yellow
docker compose build

Write-Host "🚀  Запускаем контейнеры…" -ForegroundColor Yellow
docker compose up -d

# 4. Ожидание Postgres
Write-Host "⏳  Ждём Postgres…" -NoNewline
while (-not (docker compose exec -T search-db pg_isready -U postgres 2>$null)) {
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 1
}
Write-Host " OK"

# 5. Миграция/импорт
Write-Host "📦  Импорт прайса…" -ForegroundColor Yellow
docker compose exec -T price-search-service `
    node scripts/load_prices_to_pg.js /app/products_sample.json

Write-Host "`n✅  Запуск завершён!
    • Web-Agent:   http://localhost:3000
    • Search API: http://localhost:4001/v1/products/search?q=лист`n"
