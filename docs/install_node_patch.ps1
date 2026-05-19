param(
  [string]$ProjectRoot = ".",
  [string]$DestServicesDir = "src\services",   # скорректируй под свой проект
  [string]$DestIntentsDir = "src\intents"      # скорректируй под свой проект
)

$ErrorActionPreference = "Stop"

# 1) Копируем searchClient.js
$srcClient = Join-Path "." "node_patch\searchClient.js"
$dstClientDir = Join-Path $ProjectRoot $DestServicesDir
$dstClient = Join-Path $dstClientDir "searchClient.js"

if (!(Test-Path $dstClientDir)) { New-Item -ItemType Directory -Force -Path $dstClientDir | Out-Null }
Copy-Item $srcClient $dstClient -Force
Write-Host "Placed $dstClient"

# 2) Кладём пример хендлеров (как убрать this.say)
$srcHandlers = Join-Path "." "node_patch\intentHandlers.sample.js"
$dstIntentsDir = Join-Path $ProjectRoot $DestIntentsDir
$dstHandlers = Join-Path $dstIntentsDir "intentHandlers.sample.js"
if (!(Test-Path $dstIntentsDir)) { New-Item -ItemType Directory -Force -Path $dstIntentsDir | Out-Null }
Copy-Item $srcHandlers $dstHandlers -Force
Write-Host "Placed $dstHandlers"

# 3) Подсказываем по .env
$envFile = Join-Path $ProjectRoot ".env"
$hint = @"
# --- search backend ---
USE_PY_SEARCH=true
SEARCH_API=http://127.0.0.1:5051
REQUIRE_DB=true
"@

if (Test-Path $envFile) {
  Add-Content -Path $envFile -Value $hint
  Write-Host "Appended search settings into .env"
} else {
  Set-Content -Path $envFile -Value $hint
  Write-Host "Created .env with search settings"
}

Write-Host "Done. Теперь поправь импорты на searchClient.js в своих хендлерах и убери this.say."