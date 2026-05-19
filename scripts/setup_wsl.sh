#!/usr/bin/env bash
set -euo pipefail

# 1. Проверка Docker
if ! command -v docker >/dev/null 2>&1; then
  echo "❌  Docker не найден. Установите Docker (WSL2 backend) и перезапустите терминал."
  exit 1
fi
if ! command -v docker compose >/dev/null 2>&1; then
  echo "❌  Не найден docker compose (v2). Установите пакет docker-compose-plugin."
  exit 1
fi

# 2. Копируем .env
[[ -f .env ]] || cp .env.example .env

# 3. Сборка/запуск
echo "🔧  Собираем образы…"
docker compose build

echo "🚀  Запускаем стэк…"
docker compose up -d

# 4. Ожидаем Postgres
echo -n "⏳  Ждём старт Postgres "
until docker compose exec -T search-db pg_isready -U postgres >/dev/null 2>&1; do
  echo -n "."
  sleep 1
done
echo " OK"

# 5. Миграции и загрузка прайса
echo "📦  Миграции / импорт прайса…"
docker compose exec -T price-search-service \
  node scripts/load_prices_to_pg.js /app/products_sample.json

echo "✅  Готово!  Web-Agent: http://localhost:3000  |  Search API: http://localhost:4001/health"
