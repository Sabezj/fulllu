#!/usr/bin/env bash
set -euo pipefail
# dbctl.sh — PostgreSQL installer/manager for products+carts app
# Requires: bash, sudo (for install/service ops), psql, pg_dump, jq in PATH after install.
# Version: 2.0.5
# ------------------------------

# ------------------------------
# Config (can be overridden via env or .env)
# ------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && set -a && . "$SCRIPT_DIR/.env" && set +a
: "${DB_NAME:=db}"
: "${DB_USER:=postgres}"
: "${DB_PASS:=postgres}"
: "${DB_HOST:=localhost}"
: "${DB_PORT:=5432}"
: "${PG_EXTENSIONS:=pg_trgm}"
: "${PG_FTS_LANGUAGE:=simple}" # For full-text search
: "${PG_LISTEN_ADDRESSES:=localhost}"
: "${PG_MAX_CONNECTIONS:=100}"
: "${PG_SHARED_BUFFERS:=256MB}"
: "${PG_WORK_MEM:=8MB}"
: "${PG_MAINTENANCE_WORK_MEM:=128MB}"
: "${PG_LOGGING_COLLECTOR:=on}"
: "${PG_WAIT_TIMEOUT:=30}"
PRODUCTS_CSV=""
SQL_FILE=""
JSON_FILE=""
BACKUP_FILE="backup_$(date +%Y%m%d_%H%M%S).sql"
SCRIPT_VERSION="2.0.5"

# ------------------------------
# Helpers
# ------------------------------
log() { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || err "Missing command: $1"; }
check_sudo() {
  if [ "$(id -u)" -ne 0 ]; then
    sudo -n true 2>/dev/null || err "sudo privileges required for this operation."
  fi
}
psql_cmd() {
  local conn="host=${DB_HOST} port=${DB_PORT} dbname=${1:-postgres} user=${DB_USER} sslmode=prefer"
  psql "${conn}" -v ON_ERROR_STOP=1 -q "${@:2}" 2> >(grep -v "SSL connection" >&2)
}
psql_super() {
  if id postgres >/dev/null 2>&1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -q "$@"
  else
    psql -v ON_ERROR_STOP=1 -q "$@"
  fi
}
quote_ident() {
  psql_super -t -c "SELECT quote_ident('$1');" | tr -d '[:space:]'
}
detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then echo "macos"; return; fi
  if [ -f /etc/debian_version ]; then echo "debian"; return; fi
  if [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || [ -f /etc/fedora-release ]; then echo "rhel"; return; fi
  if [ -f /etc/arch-release ]; then echo "arch"; return; fi
  echo "unknown"
}
pg_service_name() {
  local os; os=$(detect_os)
  case "$os" in
    macos)
      if brew list postgresql@16 >/dev/null 2>&1; then echo "postgresql@16"; else echo "postgresql"; fi ;;
    debian)
      systemctl list-units --type=service | grep -oE 'postgresql(-[0-9]+)?\.service' | head -n1 || echo "postgresql" ;;
    rhel|arch)
      systemctl list-units --type=service | grep -oE 'postgresql(-[0-9]+)?\.service' | head -n1 || echo "postgresql" ;;
    *) echo "postgresql" ;;
  esac
}
pg_config_file() {
  psql_super -t -c "SHOW config_file;" | tr -d '[:space:]'
}
pg_hba_file() {
  psql_super -t -c "SHOW hba_file;" | tr -d '[:space:]'
}
wait_for_postgres() {
  local retries="${PG_WAIT_TIMEOUT}"
  log "Waiting for PostgreSQL on ${DB_HOST}:${DB_PORT} (timeout: ${retries}s)..."
  until psql_cmd postgres -c "SELECT 1;" >/dev/null 2>&1; do
    sleep 1
    retries=$((retries-1))
    [ "$retries" -le 0 ] && err "PostgreSQL not reachable as ${DB_USER} on ${DB_HOST}:${DB_PORT}"
  done
  log "PostgreSQL is reachable."
}
usage() {
  cat <<EOF
Usage: $0 <command> [options]
Version: ${SCRIPT_VERSION}
Commands:
  install              Install PostgreSQL and start service
  start|stop|status    Manage PostgreSQL service
  configure            Adjust postgresql.conf & pg_hba.conf
  create               Create role & database (idempotent)
  migrate              Create tables, indexes, extensions (idempotent)
  import               Import data (CSV, JSON, or SQL)
  check                Run config & schema health checks
  backup [file]        Dump database to SQL (default: ${BACKUP_FILE})
  restore <file>       Restore from SQL dump (drops objects)
  uninstall            Remove PostgreSQL (keeps data on macOS)
Options (for import):
  --products-csv <path> CSV file (name,description,price_cents,sku,stock)
  --json <path>         JSON file with product data
  --sql <path>          SQL file to execute
Environment (.env supported):
  DB_NAME, DB_USER, DB_PASS, DB_HOST, DB_PORT, PG_EXTENSIONS, PG_FTS_LANGUAGE
  PG_LISTEN_ADDRESSES, PG_MAX_CONNECTIONS, PG_SHARED_BUFFERS, PG_WORK_MEM
  PG_MAINTENANCE_WORK_MEM, PG_LOGGING_COLLECTOR, PG_WAIT_TIMEOUT
Examples:
  $0 install
  $0 create
  $0 import --products-csv ./seed/products.csv
  $0 import --json ./profnastil_price.json
  $0 backup mybackup.sql
EOF
}

# ------------------------------
# Commands
# ------------------------------
cmd_install() {
  local os; os=$(detect_os)
  log "Detected OS: ${os}"
  check_sudo
  case "$os" in
    debian)
      log "Installing PostgreSQL (Debian/Ubuntu)..."
      sudo apt-get update -y
      sudo apt-get install -y postgresql postgresql-contrib
      sudo systemctl enable --now "$(pg_service_name)"
      ;;
    rhel)
      log "Installing PostgreSQL (RHEL/CentOS/Fedora)..."
      sudo dnf install -y postgresql-server postgresql-contrib || sudo yum install -y postgresql-server postgresql-contrib
      if [ ! -d "/var/lib/pgsql/data/base" ]; then
        sudo postgresql-setup --initdb || sudo /usr/pgsql-*/bin/postgresql-*-setup initdb
      fi
      sudo systemctl enable --now "$(pg_service_name)"
      ;;
    arch)
      log "Installing PostgreSQL (Arch Linux)..."
      sudo pacman -S --noconfirm postgresql
      if [ ! -d "/var/lib/postgres/data/base" ]; then
        sudo -u postgres initdb -D /var/lib/postgres/data
      fi
      sudo systemctl enable --now "$(pg_service_name)"
      ;;
    macos)
      need_cmd brew
      if ! brew list postgresql@16 >/dev/null 2>&1; then
        log "Installing PostgreSQL 16 (Homebrew)..."
        brew install postgresql@16
      fi
      brew link --force postgresql@16
      brew services start postgresql@16 || brew services start postgresql
      ;;
    *)
      err "Unsupported OS. Install PostgreSQL manually and re-run."
      ;;
  esac
  log "Ensuring superuser exists..."
  if ! psql_super -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$(whoami)';" | grep -q 1; then
    psql_super -c "CREATE ROLE \"$(whoami)\" WITH SUPERUSER LOGIN;" || warn "Failed to create superuser $(whoami)."
  fi
  log "PostgreSQL installed and service started."
}
cmd_service() {
  local action="$1" svc
  svc=$(pg_service_name)
  local os; os=$(detect_os)
  case "$os" in
    macos)
      case "$action" in
        start) brew services start "$svc" ;;
        stop) brew services stop "$svc" ;;
        status) brew services list | grep -E 'postgresql(@16)?' || true ;;
      esac
      ;;
    *)
      check_sudo
      case "$action" in
        start) sudo systemctl start "$svc" ;;
        stop) sudo systemctl stop "$svc" ;;
        status) sudo systemctl status "$svc" || true ;;
      esac
      ;;
  esac
}
cmd_configure() {
  log "Configuring PostgreSQL..."
  check_sudo
  wait_for_postgres
  psql_super <<SQL
ALTER SYSTEM SET listen_addresses = '${PG_LISTEN_ADDRESSES}';
ALTER SYSTEM SET max_connections = ${PG_MAX_CONNECTIONS};
ALTER SYSTEM SET shared_buffers = '${PG_SHARED_BUFFERS}';
ALTER SYSTEM SET work_mem = '${PG_WORK_MEM}';
ALTER SYSTEM SET maintenance_work_mem = '${PG_MAINTENANCE_WORK_MEM}';
ALTER SYSTEM SET logging_collector = '${PG_LOGGING_COLLECTOR}';
SELECT pg_reload_conf();
SQL
  local hba; hba=$(pg_hba_file)
  [ -z "$hba" ] && err "Could not locate pg_hba.conf."
  log "Ensuring md5 auth in pg_hba.conf ($hba)"
  if ! grep -qE 'host\s+all\s+all\s+127\.0\.0\.1/32\s+md5' "$hba"; then
    echo "host all all 127.0.0.1/32 md5" | sudo tee -a "$hba" >/dev/null
  fi
  if ! grep -qE 'host\s+all\s+all\s+::1/128\s+md5' "$hba"; then
    echo "host all all ::1/128 md5" | sudo tee -a "$hba" >/dev/null
  fi
  log "Reloading PostgreSQL..."
  psql_super -c "SELECT pg_reload_conf();"
  log "Configuration updated."
}
cmd_create() {
  log "Creating role and database..."
  local quoted_user quoted_db
  quoted_user=$(quote_ident "${DB_USER}")
  quoted_db=$(quote_ident "${DB_NAME}")
  # Create role if it doesn't exist
  psql_super <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${quoted_user}') THEN
    EXECUTE 'CREATE ROLE ${quoted_user} LOGIN PASSWORD ' || quote_literal('${DB_PASS}');
  END IF;
END
\$\$;
SQL
  # Check if database exists
  if ! psql_super -tAc "SELECT 1 FROM pg_database WHERE datname = '${quoted_db}';" | grep -q 1; then
    log "Database '${DB_NAME}' does not exist, creating..."
    psql_super -c "CREATE DATABASE ${quoted_db} OWNER ${quoted_user};"
  else
    log "Database '${DB_NAME}' already exists, skipping creation."
  fi
  wait_for_postgres
  log "Role '${DB_USER}' and database '${DB_NAME}' created."
}
cmd_migrate() {
  wait_for_postgres
  log "Enabling extensions: ${PG_EXTENSIONS}"
  IFS=',' read -ra exts <<<"$PG_EXTENSIONS"
  for ext in "${exts[@]}"; do
    ext_trim="$(echo "$ext" | xargs)"
    [ -z "$ext_trim" ] && continue
    quoted_ext=$(quote_ident "${ext_trim}")
    psql_cmd "${DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS ${quoted_ext};" || warn "Extension ${ext_trim} not available."
  done
  log "Creating schema (products, carts, cart_items)..."
  psql_cmd "${DB_NAME}" <<SQL
BEGIN;
-- Schema versioning
CREATE TABLE IF NOT EXISTS schema_version (
  version INT PRIMARY KEY,
  applied_at TIMESTAMP DEFAULT NOW()
);
INSERT INTO schema_version (version) VALUES (1)
ON CONFLICT (version) DO NOTHING;

CREATE TABLE IF NOT EXISTS products (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  price_cents INT NOT NULL CHECK (price_cents >= 0),
  sku TEXT UNIQUE NOT NULL,
  stock INT NOT NULL DEFAULT 0 CHECK (stock >= 0),
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'products_search_idx'
  ) THEN
    EXECUTE 'CREATE INDEX products_search_idx ON products USING GIN (to_tsvector(''${PG_FTS_LANGUAGE}'', name || '' '' || coalesce(description,'''')))';
  END IF;
END\$\$;
CREATE TABLE IF NOT EXISTS carts (
  id BIGSERIAL PRIMARY KEY,
  user_id BIGINT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'submitted', 'cancelled')),
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS cart_items (
  cart_id BIGINT REFERENCES carts(id) ON DELETE CASCADE,
  product_id BIGINT REFERENCES products(id),
  qty INT NOT NULL CHECK (qty > 0),
  price_cents_at_add INT NOT NULL CHECK (price_cents_at_add >= 0),
  PRIMARY KEY (cart_id, product_id)
);
COMMIT;
SQL
  log "Migrations complete (schema version 1)."
}
cmd_import() {
  wait_for_postgres
  need_cmd jq
  while (( "$#" )); do
    case "$1" in
      --products-csv) PRODUCTS_CSV="$2"; shift 2;;
      --json) JSON_FILE="$2"; shift 2;;
      --sql) SQL_FILE="$2"; shift 2;;
      *) err "Unknown import option: $1";;
    esac
  done
  if [ -n "$SQL_FILE" ]; then
    [ -f "$SQL_FILE" ] || err "SQL file not found: $SQL_FILE"
    log "Executing SQL file: $SQL_FILE"
    psql_cmd "${DB_NAME}" -f "$SQL_FILE"
  fi
  if [ -n "$PRODUCTS_CSV" ]; then
    [ -f "$PRODUCTS_CSV" ] || err "CSV not found: $PRODUCTS_CSV"
    log "Validating CSV headers..."
    head -n1 "$PRODUCTS_CSV" | grep -qE '^name,description,price_cents,sku,stock$' || err "Invalid CSV headers. Expected: name,description,price_cents,sku,stock"
    log "Importing products from CSV: $PRODUCTS_CSV"
    psql_cmd "${DB_NAME}" <<SQL
CREATE TEMP TABLE _products_import (
  name TEXT,
  description TEXT,
  price_cents INT,
  sku TEXT,
  stock INT
);
\COPY _products_import(name,description,price_cents,sku,stock) FROM '${PRODUCTS_CSV}' CSV HEADER
INSERT INTO products (name, description, price_cents, sku, stock)
SELECT DISTINCT ON (sku) name, description, price_cents, sku, stock
FROM _products_import
WHERE sku IS NOT NULL AND price_cents IS NOT NULL AND stock IS NOT NULL
ON CONFLICT (sku)
DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  price_cents = EXCLUDED.price_cents,
  stock = EXCLUDED.stock;
SQL
    log "Products CSV import complete."
  fi
  if [ -n "$JSON_FILE" ]; then
    [ -f "$JSON_FILE" ] || err "JSON file not found: $JSON_FILE"
    log "Importing products from JSON: $JSON_FILE"
    # Create a temporary CSV file
    local temp_csv=$(mktemp /tmp/products_import.XXXXXX.csv)
    jq -r '.[] | [
      .["Наименование продукции"],
      (.["Общая ширина профиля (мм)"] | tostring) + " мм общая ширина, " +
      (if .["Рабочая ширина профиля (мм)"] then .["Рабочая ширина профиля (мм)"] | tostring + " мм рабочая ширина, " else "" end) +
      (.["Толщина металла (мм)"] | tostring) + " мм толщина, " +
      .["Покрытие"],
      (.["Цена м² (руб)"] * 100 | floor),
      .["Наименование продукции"] + "_" + (.["Толщина металла (мм)"] | tostring) + "_" + (.["Общая ширина профиля (мм)"] | tostring),
      0
    ] | @csv' "$JSON_FILE" > "$temp_csv" || err "Failed to process JSON file with jq"
    # Check for duplicate SKUs
    local duplicate_skus
    duplicate_skus=$(jq -r '.[] | .["Наименование продукции"] + "_" + (.["Толщина металла (мм)"] | tostring) + "_" + (.["Общая ширина профиля (мм)"] | tostring)' "$JSON_FILE" | sort | uniq -d)
    if [ -n "$duplicate_skus" ]; then
      warn "Duplicate SKUs detected in JSON data:\n$duplicate_skus\nUsing last occurrence for each SKU."
    fi
    # Import CSV in a single psql session
    psql_cmd "${DB_NAME}" <<SQL
CREATE TEMP TABLE _products_import (
  name TEXT,
  description TEXT,
  price_cents INT,
  sku TEXT,
  stock INT
);
\COPY _products_import(name,description,price_cents,sku,stock) FROM '${temp_csv}' CSV
INSERT INTO products (name, description, price_cents, sku, stock)
SELECT DISTINCT ON (sku) name, description, price_cents, sku, stock
FROM _products_import
WHERE sku IS NOT NULL AND price_cents IS NOT NULL AND stock IS NOT NULL
ON CONFLICT (sku)
DO UPDATE SET
  name = EXCLUDED.name,
  description = EXCLUDED.description,
  price_cents = EXCLUDED.price_cents,
  stock = EXCLUDED.stock;
SQL
    # Clean up temporary file
    rm -f "$temp_csv"
    log "Products JSON import complete."
  fi
  if [ -z "$PRODUCTS_CSV" ] && [ -z "$SQL_FILE" ] && [ -z "$JSON_FILE" ]; then
    warn "Nothing to import. Provide --products-csv, --json, or --sql."
  fi
}
cmd_check() {
  wait_for_postgres
  log "Checking DB connectivity as ${DB_USER}..."
  psql_cmd "${DB_NAME}" -c "SELECT version();" | sed 's/^/ /'
  log "Running schema checks..."
  psql_cmd "${DB_NAME}" <<SQL
SELECT 'schema_version' AS table, COUNT(*) FROM schema_version;
SELECT 'products' AS table, COUNT(*) FROM products;
SELECT 'carts' AS table, COUNT(*) FROM carts;
SELECT 'cart_items' AS table, COUNT(*) FROM cart_items;
SELECT indexname, indexdef FROM pg_indexes WHERE tablename='products' ORDER BY 1;
SELECT 'orphaned_cart_items' AS check, COUNT(*) FROM cart_items ci
WHERE NOT EXISTS (SELECT 1 FROM carts c WHERE c.id = ci.cart_id)
   OR NOT EXISTS (SELECT 1 FROM products p WHERE p.id = ci.product_id);
SQL
  log "Testing product search (FTS + ILIKE)..."
  psql_cmd "${DB_NAME}" <<SQL
WITH q AS (SELECT 'test'::text AS term)
SELECT id, name, price_cents
FROM products, q
WHERE to_tsvector('${PG_FTS_LANGUAGE}', name || ' ' || coalesce(description,'')) @@ plainto_tsquery('${PG_FTS_LANGUAGE}', q.term)
   OR name ILIKE '%'||q.term||'%'
LIMIT 5;
SQL
  log "Testing cart upsert logic (dry-run)..."
  psql_cmd "${DB_NAME}" <<SQL
BEGIN;
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM products) THEN
    RAISE NOTICE 'No products available to test cart.';
  ELSE
    WITH c AS (
      INSERT INTO carts (user_id, status)
      SELECT 42, 'open'
      WHERE NOT EXISTS (SELECT 1 FROM carts WHERE user_id=42 AND status='open')
      RETURNING id
    )
    SELECT * FROM c;
    INSERT INTO cart_items (cart_id, product_id, qty, price_cents_at_add)
    SELECT (SELECT id FROM carts WHERE user_id=42 AND status='open' LIMIT 1),
           (SELECT id FROM products LIMIT 1), 1, (SELECT price_cents FROM products LIMIT 1)
    ON CONFLICT (cart_id, product_id)
    DO UPDATE SET qty = cart_items.qty + EXCLUDED.qty;
    SELECT 'cart_total' AS label,
           SUM(ci.qty * ci.price_cents_at_add) AS total_cents
    FROM cart_items ci
    WHERE ci.cart_id = (SELECT id FROM carts WHERE user_id=42 AND status='open' LIMIT 1);
  END IF;
END\$\$;
ROLLBACK;
SQL
  log "All checks complete."
}
cmd_backup() {
  wait_for_postgres
  local out="${1:-$BACKUP_FILE}"
  log "Dumping database '${DB_NAME}' to ${out}"
  need_cmd pg_dump
  pg_dump -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -F p -f "${out}" "${DB_NAME}"
  log "Backup complete: ${out}"
}
cmd_restore() {
  local file="${1:-}"
  [ -z "$file" ] && err "Usage: $0 restore <file.sql>"
  [ -f "$file" ] || err "File not found: $file"
  warn "This will DROP and recreate objects in ${DB_NAME}. Continue? [y/N]"
  read -rp "" ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]] || { log "Aborted."; return 0; }
  wait_for_postgres
  log "Restoring ${file} into ${DB_NAME}"
  psql_cmd "${DB_NAME}" -f "${file}"
  log "Restore complete."
}
cmd_uninstall() {
  local os; os=$(detect_os)
  warn "This will uninstall PostgreSQL binaries (data may remain). Continue? [y/N]"
  read -rp "" ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]] || { log "Aborted."; return 0; }
  check_sudo
  case "$os" in
    debian)
      sudo systemctl stop "$(pg_service_name)" || true
      sudo apt-get remove -y postgresql postgresql-contrib || true
      ;;
    rhel)
      sudo systemctl stop "$(pg_service_name)" || true
      sudo dnf remove -y postgresql-server postgresql-contrib || sudo yum remove -y postgresql-server postgresql-contrib || true
      ;;
    arch)
      sudo systemctl stop "$(pg_service_name)" || true
      sudo pacman -R --noconfirm postgresql postgresql-libs || true
      ;;
    macos)
      if brew list postgresql@16 >/dev/null 2>&1; then
        brew services stop postgresql@16 || true
        brew uninstall postgresql@16 || true
      else
        brew services stop postgresql || true
        brew uninstall postgresql || true
      fi
      ;;
    *)
      err "Unsupported OS for uninstall."
      ;;
  esac
  log "PostgreSQL uninstalled (data dirs may still exist)."
}
# ------------------------------
# Main
# ------------------------------
main() {
  # Setup ~/.pgpass if DB_PASS is set
  if [ -n "${DB_PASS}" ]; then
    local pgpass_file="${HOME}/.pgpass"
    local pgpass_entry="${DB_HOST}:${DB_PORT}:*:${DB_USER}:${DB_PASS}"
    if ! grep -Fx "$pgpass_entry" "$pgpass_file" >/dev/null 2>&1; then
      echo "$pgpass_entry" >> "$pgpass_file"
      chmod 600 "$pgpass_file"
      log "Added credentials to ~/.pgpass"
    fi
  fi
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    install) cmd_install ;;
    start) cmd_service start ;;
    stop) cmd_service stop ;;
    status) cmd_service status ;;
    configure) cmd_configure ;;
    create) cmd_create ;;
    migrate) cmd_migrate ;;
    import) cmd_import "$@" ;;
    check) cmd_check ;;
    backup) cmd_backup "$@" ;;
    restore) cmd_restore "$@" ;;
    uninstall) cmd_uninstall ;;
    ""|help|-h|--help) usage ;;
    *) err "Unknown command: $cmd. Run: $0 help" ;;
  esac
}
main "$@"

