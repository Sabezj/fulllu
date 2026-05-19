<#
dbctl.ps1 — PostgreSQL installer / manager (Windows edition)
Версия: 2.0.5-ps
Usage:
  .\dbctl.ps1 <command> [options]

Команды:
  install                Установить PostgreSQL + jq (Chocolatey)
  start|stop|status      Управление службой PostgreSQL
  configure              Настроить postgresql.conf и pg_hba.conf
  create                 Создать роль и базу (идемпотентно)
  migrate                Создать/обновить схему (idempotent)
  import  [--products-csv <file>] [--json <file>] [--sql <file>]
  check                  Быстрые проверки конфигурации и схемы
  backup  [file]         pg_dump базы (по умолчанию backup_YYYYMMDD_HHMMSS.sql)
  restore <file>         Восстановить из дампа
  uninstall              Удалить PostgreSQL (данные НЕ удаляются)
  help                   Показать помощь
#>

param (
    [Parameter(Position = 0)] [string] $Command = "help",
    [string[]] $Args
)

# ------------- Конфигурация -------------
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile     = Join-Path $ScriptDir ".env"
if (Test-Path $EnvFile) {
    Get-Content $EnvFile | Where-Object {$_ -match '^\s*[^#]'} |
        ForEach-Object {
            if ($_ -match '^\s*([^=]+)=(.*)$') {
                [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2])
            }
        }
}

function Default($value, $fallback) {
    if ($null -eq $value -or $value -eq '') { return $fallback }
    return $value
}

$DB_NAME         = Default $env:DB_NAME         "db"
$DB_USER         = Default $env:DB_USER         "postgres"
$DB_PASS         = Default $env:DB_PASS         "postgres"
$DB_HOST         = Default $env:DB_HOST         "localhost"
$DB_PORT         = Default $env:DB_PORT         5432
$PG_EXTENSIONS   = Default $env:PG_EXTENSIONS   "pg_trgm"
$PG_FTS_LANGUAGE = Default $env:PG_FTS_LANGUAGE "simple"
$BACKUP_FILE     = "backup_{0:yyyyMMdd_HHmmss}.sql" -f (Get-Date)

# Путь до бинарей PostgreSQL (измените при необходимости)
$PG_BIN = "C:\Program Files\PostgreSQL\17\bin"

# ------------- Хелперы -------------
function Write-Log   { param($m) Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" -ForegroundColor Cyan }
function Write-Warn  { param($m) Write-Host "[WARN] $m"                    -ForegroundColor Yellow }
function Write-Err   { param($m) Write-Host "[ERR]  $m"                    -ForegroundColor Red; exit 1 }

function Need-Cmd($cmd) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Err "Команда '$cmd' не найдена в PATH."
    }
}

function Psql ($sql, [string]$db = "postgres", [switch]$Quiet) {
    Need-Cmd "psql"
    $env:PGPASSWORD = $DB_PASS
    $quietFlag = ""
	if ($Quiet.IsPresent) { $quietFlag = "-q" }
    & psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $db -v ON_ERROR_STOP=1 $quietFlag -c $sql
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
}

function Wait-Postgres() {
    Write-Log "Ожидание подключения к PostgreSQL ${DB_HOST}:${DB_PORT}..."
    for ($i=0; $i -lt 30; $i++) {
        try { Psql "SELECT 1;" -Quiet; return } catch { Start-Sleep 1 }
    }
    Write-Err "Не удалось подключиться к PostgreSQL."
}

function Service-Name() {
    # Имя службы можно узнать `Get-Service *postgres*`
    return "postgresql-x64-17"
}

# ------------- Команды -------------
function Install {
    Write-Log "Установка PostgreSQL + jq через Chocolatey..."
    Need-Cmd "choco"
    choco install postgresql jq -y
    Write-Log "Добавляем bin в PATH..."
    $pgBin = (Get-ChildItem "C:\Program Files\PostgreSQL\" -Directory |
              Sort-Object Name -Descending |
              Select-Object -First 1).FullName + "\bin"
    [Environment]::SetEnvironmentVariable("PATH", $env:PATH + ";$pgBin", "Machine")
    Write-Log "Initdb..."
    & "$pgBin\pg_ctl.exe" init -D "C:\pgdata"
    & sc.exe create (Service-Name) binPath= "`"$pgBin\pg_ctl.exe run -D C:\pgdata -w`""
    Start
}

function Start  { sc.exe start  (Service-Name) | Out-Null; Wait-Postgres }
function Stop   { sc.exe stop   (Service-Name) | Out-Null }
function Status { Get-Service (Service-Name)  }

function Configure {
    Wait-Postgres
    Write-Log "Настройка postgresql.conf..."
    Psql "ALTER SYSTEM SET listen_addresses = 'localhost';"
    Psql "ALTER SYSTEM SET shared_buffers   = '256MB';"
    Psql "ALTER SYSTEM SET work_mem         = '8MB';"
    Psql "SELECT pg_reload_conf();" -Quiet
    Write-Log "Обновлено."
}

function Create {
    Wait-Postgres
    Write-Log "Создание роли/БД (если отсутствуют)..."
    Psql "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$DB_USER') THEN
    EXECUTE 'CREATE ROLE $DB_USER LOGIN PASSWORD ''$DB_PASS''';
  END IF;
END\$\$;
" -Quiet
    Psql "CREATE DATABASE $DB_NAME OWNER $DB_USER;" -Quiet
    Write-Log "Готово."
}

function Migrate {
    Wait-Postgres
    Write-Log "Подключаем расширения: $PG_EXTENSIONS"
    foreach ($ext in $PG_EXTENSIONS.Split(',')) {
        Psql "CREATE EXTENSION IF NOT EXISTS $ext;" $DB_NAME -Quiet
    }
    Write-Log "Создание схемы…"
    Psql @"
BEGIN;
CREATE TABLE IF NOT EXISTS schema_version (version INT PRIMARY KEY, applied_at TIMESTAMP DEFAULT NOW());
INSERT INTO schema_version (version) VALUES (1) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS products (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  price_cents INT NOT NULL CHECK (price_cents >= 0),
  sku TEXT UNIQUE NOT NULL,
  stock INT NOT NULL DEFAULT 0 CHECK (stock >= 0),
  created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS products_search_idx
  ON products USING GIN (to_tsvector('$PG_FTS_LANGUAGE', name || ' ' || coalesce(description,'')));

CREATE TABLE IF NOT EXISTS carts (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','submitted','cancelled')),
  created_at TIMESTAMP DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS cart_items (
  cart_id BIGINT REFERENCES carts(id) ON DELETE CASCADE,
  product_id BIGINT REFERENCES products(id),
  qty INT NOT NULL CHECK (qty > 0),
  price_cents_at_add INT NOT NULL CHECK (price_cents_at_add >= 0),
  PRIMARY KEY (cart_id, product_id)
);
COMMIT;
"@ $DB_NAME -Quiet
    Write-Log "Миграции завершены."
}

function Import {
    param([string]$productsCsv, [string]$json, [string]$sql)
    Wait-Postgres
    if ($sql)  { Psql "\i $sql" $DB_NAME; return }
    if ($productsCsv) {
        if (-not (Test-Path $productsCsv)) { Write-Err "CSV не найден: $productsCsv" }
        Write-Log "Импорт CSV: $productsCsv"
        Psql @"
CREATE TEMP TABLE _import(name TEXT, description TEXT, price_cents INT, sku TEXT, stock INT);
\COPY _import FROM '$productsCsv' CSV HEADER;
INSERT INTO products (name, description, price_cents, sku, stock)
SELECT DISTINCT ON (sku) * FROM _import
ON CONFLICT (sku) DO UPDATE
  SET name=EXCLUDED.name,
      description=EXCLUDED.description,
      price_cents=EXCLUDED.price_cents,
      stock=EXCLUDED.stock;
"@ $DB_NAME
    }
    if ($json) {
        if (-not (Test-Path $json)) { Write-Err "JSON не найден: $json" }
        Need-Cmd "jq"
        $tmp = [System.IO.Path]::GetTempFileName() + ".csv"
        Write-Log "Преобразование JSON > CSV…"
        & jq -r '
          .[] | [
            .["Наименование продукции"],
            ((.["Толщина металла (мм)"]|tostring) + " мм"),
            (.["Цена м? (руб)"]*100|floor),
            (.["Наименование продукции"] + "_" + (.["Толщина металла (мм)"]|tostring)),
            0
          ] | @csv' $json > $tmp
        Import -productsCsv $tmp
        Remove-Item $tmp
    }
}

function Check {
    Wait-Postgres
    Write-Log "Версия сервера:"
    Psql "SELECT version();" $DB_NAME
    Write-Log "Статистика по таблицам:"
    Psql "SELECT relname, n_live_tup FROM pg_stat_user_tables;" $DB_NAME
}

function Backup ([string]$file = $BACKUP_FILE) {
    Need-Cmd "pg_dump"
    Wait-Postgres
    Write-Log "Дамп ${DB_NAME} > $file"
    $env:PGPASSWORD = $DB_PASS
    & pg_dump -h $DB_HOST -p $DB_PORT -U $DB_USER -F p -f $file $DB_NAME
    Write-Log "Готово."
}

function Restore ([Parameter(Mandatory)][string]$file) {
    if (-not (Test-Path $file)) { Write-Err "Файл $file не найден." }
    Wait-Postgres
    Write-Warn "ВНИМАНИЕ: объекты в $DB_NAME будут перезаписаны!"
    $ans = Read-Host "Продолжить? (y/N)"
    if ($ans -notin @('y','Y')) { return }
    Psql "\i $file" $DB_NAME
    Write-Log "Восстановление завершено."
}

function Uninstall {
    Write-Warn "Удаление PostgreSQL (бинарей). Данные в C:\pgdata сохранятся."
    $ans = Read-Host "Продолжить? (y/N)"
    if ($ans -notin @('y','Y')) { return }
    Stop
    choco uninstall postgresql -y
    Write-Log "Готово."
}

function Help {
@"
Usage: dbcfgm.ps1 <command> [options]

Commands:
  install       — установить PostgreSQL через Chocolatey
  start         — запустить службу PostgreSQL
  stop          — остановить службу
  status        — проверить статус службы
  configure     — обновить postgresql.conf и pg_hba.conf
  create        — создать роль и базу
  migrate       — применить схему
  import        — загрузить данные (CSV/JSON/SQL)
  check         — проверить схему и связность
  backup        — создать дамп БД
  restore       — восстановить из дампа
  uninstall     — удалить PostgreSQL
  help          — показать это сообщение
"@ | Write-Host
}

# ------------- Диспетчер -------------
switch ($Command) {
    "install"   { Install }
    "start"     { Start }
    "stop"      { Stop }
    "status"    { Status }
    "configure" { Configure }
    "create"    { Create }
    "migrate"   { Migrate }
    "import"    { Import @Args }
    "check"     { Check }
    "backup"    { Backup @Args }
    "restore"   { Restore @Args }
    "uninstall" { Uninstall }
    default     { Help }
}
