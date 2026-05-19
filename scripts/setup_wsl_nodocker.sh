#!/usr/bin/env bash
# Развёртывание без Docker (WSL2, Ubuntu)
set -euo pipefail

check() { command -v "$1" >/dev/null 2>&1 || { echo "❌  $1 not found"; exit 1; }; }

echo "🔍  Проверяем зависимости…"
check node
check npm
check python3
check psql

PG_URI=${PG_URI:-postgres://postgres:postgres@localhost:5432}

# 1. Настройка Postgres (предполагаем роль postgres c паролем postgres)
echo "🗄️  Настраиваем Postgres…"
psql "$PG_URI/postgres" -c "SELECT 1" >/dev/null

psql "$PG_URI/postgres" <<'SQL'
DO $$ BEGIN
  PERFORM 1 FROM pg_database WHERE datname = 'products';
  IF NOT FOUND THEN
    CREATE DATABASE products;
  END IF;
END $$;
SQL

psql "$PG_URI/products" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;
\i sql/01_init.sql
SQL

# 2. Импорт прайса
echo "📦  Импортируем прайс…"
python3 services/price-search/scripts/load_prices_to_pg.js profnastil_price.json

# 3. Python-env
echo "🐍  Создаём venv…"
python3 -m venv venv
source venv/bin/activate
pip install -U pip wheel
pip install -r services/price-search/requirements.txt

# 4. Node deps
echo "📦  npm ci…"
npm ci

# 5. Запуск (tmux позволяет закрыть терминал)
echo "🚀  Старт tmux-сессии 'voice'"
type tmux >/dev/null 2>&1 || { echo "Установите tmux или запустите процессы вручную"; exit 0; }

tmux new-session -d -s voice "source venv/bin/activate && uvicorn services.price-search.main:app --host 0.0.0.0 --port 4001"
tmux split-window  -t voice "npm start"
tmux attach -t voice
