"""
price_convert.py
----------------
Конвертер Excel прайсов в нормализованный каталог и загрузчик в Postgres.

Возможности:
- Разбор .xlsx/.xls (русские заголовки, десятичные запятые)
- Грубая эвристика распознавания колонок (наименование, толщина, ширина, длина, цена, ед.изм, категория, артикул)
- Нормализация: единицы измерения, числа, профили (С-8, НС-35 и т.п.), покрытие, материал
- Подготовка TSV для импорта + JSON-дамп
- (опционально) Загрузка в Postgres (таблицы: products, product_synonyms; tsvector индексы; pg_trgm/unaccent)

Использование:
    python price_convert.py "Прайс.xlsx" --sheet 0 --out-prefix out/moscow7 --to-db

Требования:
    pip install pandas openpyxl psycopg2-binary SQLAlchemy python-dotenv
    В БД:
        CREATE EXTENSION IF NOT EXISTS pg_trgm;
        CREATE EXTENSION IF NOT EXISTS unaccent;
        CREATE EXTENSION IF NOT EXISTS vector;  -- если планируете pgvector

Переменные окружения (или .env рядом):
    DATABASE_URL=postgresql+psycopg2://user:pass@localhost:5432/db
    TEXTSEARCH_CONFIG=ru                 # или simple
"""
import argparse
import os
import re
import pathlib
import math
import json
from dataclasses import dataclass, asdict
from typing import Optional, List, Dict, Any, Tuple

import pandas as pd

# Optional DB
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine
from dotenv import load_dotenv

RU_DECIMAL = re.compile(r",(?!\d{3}\b)")  # запятая как десятичный разделитель

# -------------------------- Helpers --------------------------

def to_float(v):
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return None
    s = str(v).strip()
    if s == "" or s.lower() in {"nan", "none"}:
        return None
    s = RU_DECIMAL.sub(".", s)  # заменить десятичную запятую на точку
    s = s.replace(" ", "")
    s = s.replace("мм", "").replace("м²", "").replace("м2", "").replace("м", "")
    s = s.replace(",", ".")
    try:
        return float(s)
    except:
        # вытащить первое число из строки
        m = re.search(r"[-+]?\d+(\.\d+)?", s)
        if m:
            try:
                return float(m.group(0))
            except:
                return None
        return None

def norm_str(v):
    if v is None:
        return None
    s = str(v).strip()
    s = re.sub(r"\s+", " ", s)
    return s if s else None

PROFILE_RX = re.compile(r"\b([СCCHНH]?С?-?\d{1,3})\b", re.IGNORECASE)

def guess_profile(name: str) -> Optional[str]:
    if not name:
        return None
    m = PROFILE_RX.search(name.replace(" ", ""))
    if not m:
        # еще раз по исходной строке
        m = PROFILE_RX.search(name)
    if m:
        return m.group(1).upper().replace("C", "С")  # латинская->кириллическая C
    return None

def guess_material(name: str) -> Optional[str]:
    if not name:
        return None
    s = name.lower()
    if "оцинк" in s or "оц" in s:
        return "оцинкованный"
    if "нерж" in s or "нержав" in s:
        return "нержавеющая сталь"
    if "алюм" in s or "амг" in s:
        return "алюминий"
    if "сталь" in s or "желез" in s or "металл" in s:
        return "сталь"
    return None

def guess_coating(name: str) -> Optional[str]:
    if not name:
        return None
    s = name.lower()
    if "полимер" in s or "полиэстер" in s or "пурал" in s or "пвдф" in s:
        return "полимерное покрытие"
    if "цинк" in s or "оцинк" in s:
        return "цинк"
    return None

def normalize_row(row: Dict[str, Any]) -> Dict[str, Any]:
    name = norm_str(row.get("name") or row.get("Наименование") or row.get("наименование"))
    sku = norm_str(row.get("sku") or row.get("Код") or row.get("Артикул") or row.get("арт"))
    category = norm_str(row.get("category") or row.get("Категория"))
    unit = norm_str(row.get("unit") or row.get("Ед.") or row.get("ед"))
    price = row.get("price") or row.get("Цена") or row.get("цена") or row.get("Стоимость")
    price = to_float(price)

    thickness = to_float(row.get("thickness") or row.get("Толщина") or row.get("толщина"))
    width = to_float(row.get("width") or row.get("Ширина") or row.get("ширина"))
    length = to_float(row.get("length") or row.get("Длина") or row.get("длина"))

    # Авто-детекция по имени
    prof = guess_profile(name or "")
    material = guess_material(name or "")
    coating = guess_coating(name or "")

    return {
        "name": name,
        "sku": sku,
        "category": category,
        "unit": unit or ("м²" if "м2" in (str(row.get("Ед.") or "")).lower() else "шт"),
        "price_rub": price,
        "thickness_mm": thickness,
        "width_mm": width,
        "length_mm": length,
        "material": material,
        "coating": coating,
        "profile_mark": prof,
        "attrs": {},
    }

CANDIDATE_NAME = {"наименование", "позиция", "товар", "название", "name"}
CANDIDATE_PRICE = {"цена", "стоимость", "price", "руб", "руб/м2", "руб/м²", "руб/шт"}
CANDIDATE_THICK = {"толщина", "толщ, мм", "толщина, мм", "t", "thickness"}
CANDIDATE_WIDTH = {"ширина", "ширина, мм", "w", "width"}
CANDIDATE_LENGTH = {"длина", "длина, мм", "l", "length"}
CANDIDATE_UNIT = {"ед.", "ед", "unit", "единица"}
CANDIDATE_CATEGORY = {"категория", "группа", "раздел", "category"}
CANDIDATE_SKU = {"артикул", "код", "sku", "id", "код товара"}

def map_columns(df: pd.DataFrame) -> Dict[str, str]:
    cols = [str(c).strip() for c in df.columns]
    low = [c.lower() for c in cols]
    mapping = {}

    def pick(cands, target):
        for i, lc in enumerate(low):
            base = lc.replace(".", "").replace(",", "").replace("  ", " ")
            if lc in cands or base in cands:
                mapping[target] = cols[i]
                return True
        return False

    pick(CANDIDATE_NAME, "name")
    pick(CANDIDATE_PRICE, "price")
    pick(CANDIDATE_THICK, "Толщина")
    pick(CANDIDATE_WIDTH, "Ширина")
    pick(CANDIDATE_LENGTH, "Длина")
    pick(CANDIDATE_UNIT, "Ед.")
    pick(CANDIDATE_CATEGORY, "Категория")
    pick(CANDIDATE_SKU, "Артикул")
    return mapping

# -------------------------- DB --------------------------

SCHEMA_SQL = r"""
-- Основные таблицы
CREATE TABLE IF NOT EXISTS products (
    id BIGSERIAL PRIMARY KEY,
    sku TEXT,
    name TEXT NOT NULL,
    category TEXT,
    unit TEXT DEFAULT 'шт',
    price_rub NUMERIC,
    thickness_mm NUMERIC,
    width_mm NUMERIC,
    length_mm NUMERIC,
    material TEXT,
    coating TEXT,
    profile_mark TEXT,
    attrs JSONB DEFAULT '{}'::jsonb,
    ts tsvector
);

-- Синонимы для поиска (железный->стальной/оцинкованный и т.п.)
CREATE TABLE IF NOT EXISTS product_synonyms (
    id BIGSERIAL PRIMARY KEY,
    term TEXT NOT NULL,
    norm TEXT NOT NULL
);

-- Текстовые индексы
CREATE INDEX IF NOT EXISTS idx_products_name_trgm ON products USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_products_ts     ON products USING gin (ts);

-- Обновление tsvector (ru конфигурация если доступна)
CREATE OR REPLACE FUNCTION set_products_ts() RETURNS trigger AS $$
BEGIN
  NEW.ts := to_tsvector(COALESCE(current_setting('app.textsearch_config', true), 'simple'), 
              unaccent(COALESCE(NEW.name,''))) ||
            to_tsvector(COALESCE(current_setting('app.textsearch_config', true), 'simple'),
              unaccent(COALESCE(NEW.category,'')));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_products_ts ON products;
CREATE TRIGGER trg_products_ts BEFORE INSERT OR UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION set_products_ts();
"""

# -------------------------- Core --------------------------

def read_excel(path: str, sheet):
    if isinstance(sheet, int):
        df = pd.read_excel(path, sheet_name=sheet, engine="openpyxl")
    else:
        df = pd.read_excel(path, sheet_name=str(sheet), engine="openpyxl")
    return df

def ingest_df(df: pd.DataFrame) -> Tuple[pd.DataFrame, List[Dict[str, Any]]]:
    mapping = map_columns(df)
    if "name" not in mapping:
        # Попробуем угадать первый столбец как наименование
        mapping["name"] = df.columns[0]

    normalized_rows = []
    for _, row in df.iterrows():
        # пропуск пустых строк
        if str(row.get(mapping.get("name"))).strip() in ("", "nan", "None"):
            continue
        raw = {
            "name": row.get(mapping.get("name")),
            "sku": row.get(mapping.get("Артикул")) if mapping.get("Артикул") else None,
            "Категория": row.get(mapping.get("Категория")) if mapping.get("Категория") else None,
            "Ед.": row.get(mapping.get("Ед.")) if mapping.get("Ед.") else None,
            "price": row.get(mapping.get("price")) if mapping.get("price") else None,
            "Толщина": row.get(mapping.get("Толщина")) if mapping.get("Толщина") else None,
            "Ширина": row.get(mapping.get("Ширина")) if mapping.get("Ширина") else None,
            "Длина": row.get(mapping.get("Длина")) if mapping.get("Длина") else None,
        }
        norm = normalize_row(raw)
        normalized_rows.append(norm)

    ndf = pd.DataFrame(normalized_rows)
    # Удалить явный мусор / дубликаты по name+thickness
    before = len(ndf)
    ndf.drop_duplicates(subset=["name", "thickness_mm", "width_mm", "length_mm", "price_rub"], inplace=True)
    ndf.reset_index(drop=True, inplace=True)
    return ndf, normalized_rows

def load_env():
    load_dotenv()
    db_url = os.getenv("DATABASE_URL")
    tsc = os.getenv("TEXTSEARCH_CONFIG", "ru")
    return db_url, tsc

def ensure_db(engine: Engine, textsearch_config: str = "ru"):
    with engine.begin() as conn:
        conn.execute(text("CREATE EXTENSION IF NOT EXISTS pg_trgm;"))
        conn.execute(text("CREATE EXTENSION IF NOT EXISTS unaccent;"))
        # vector — опционально, не ошибка, если нет
        try:
            conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector;"))
        except Exception:
            pass
        # Сетап функции и индексов
        for stmt in SCHEMA_SQL.strip().split(";\n\n"):
            if stmt.strip():
                conn.execute(text(stmt + ";"))
        # Сетап конфигурации приложения (ru/simple)
        conn.execute(text("SELECT set_config('app.textsearch_config', :cfg, true);"), {"cfg": textsearch_config})

def upsert_products(engine: Engine, df: pd.DataFrame) -> int:
    rows = df.to_dict(orient="records")
    up_sql = text("""
        INSERT INTO products (sku, name, category, unit, price_rub, thickness_mm, width_mm, length_mm, material, coating, profile_mark, attrs)
        VALUES (:sku, :name, :category, :unit, :price_rub, :thickness_mm, :width_mm, :length_mm, :material, :coating, :profile_mark, CAST(:attrs AS jsonb))
        ON CONFLICT (id) DO NOTHING;
    """)
    with engine.begin() as conn:
        for r in rows:
            r = {**r, "attrs": json.dumps(r.get("attrs") or {})}
            conn.execute(up_sql, r)
    return len(rows)

def seed_synonyms(engine: Engine):
    syn = [
        ("железный", "сталь"),
        ("железные", "сталь"),
        ("железо", "сталь"),
        ("оцинковка", "оцинкованный"),
        ("оцинкованный", "оцинкованный"),
        ("оц", "оцинкованный"),
        ("жесть", "оцинкованный лист"),
        ("профлист", "профнастил"),
        ("профнастил", "профнастил"),
        ("лист", "лист"),
    ]
    with engine.begin() as conn:
        conn.execute(text("DELETE FROM product_synonyms;"))
        conn.execute(text("INSERT INTO product_synonyms(term, norm) VALUES " +
                          ",".join(["(:t"+str(i)+", :n"+str(i)+")" for i in range(len(syn))])),
                     {**{f"t{i}": t for i,(t,_) in enumerate(syn)},
                      **{f"n{i}": n for i,(_,n) in enumerate(syn)}})

def save_outputs(prefix: str, df: pd.DataFrame):
    p = pathlib.Path(prefix).parent
    p.mkdir(parents=True, exist_ok=True)
    tsv_path = f"{prefix}.tsv"
    json_path = f"{prefix}.json"
    df.to_csv(tsv_path, sep="\t", index=False)
    df.to_json(json_path, orient="records", force_ascii=False, indent=2)
    return tsv_path, json_path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("excel", help="Путь к .xlsx/.xls")
    parser.add_argument("--sheet", default=0, help="Имя листа или индекс", type=str)
    parser.add_argument("--out-prefix", default="out/catalog")
    parser.add_argument("--to-db", action="store_true", help="Загрузить в Postgres")
    parser.add_argument("--db-url", default=None, help="Перекрыть DATABASE_URL")
    parser.add_argument("--textsearch", default=None, help="Перекрыть TEXTSEARCH_CONFIG (ru/simple/...)")
    args = parser.parse_args()

    sheet = int(args.sheet) if str(args.sheet).isdigit() else args.sheet

    df = read_excel(args.excel, sheet)
    ndf, _ = ingest_df(df)

    tsv_path, json_path = save_outputs(args["out-prefix"] if isinstance(args, dict) else args.out_prefix, ndf)
    print(f"Saved: {tsv_path}\nSaved: {json_path}")

    if args.to_db:
        db_url_env, tsc_env = load_env()
        db_url = args.db_url or db_url_env
        if not db_url:
            raise SystemExit("DATABASE_URL не задан (ни в .env, ни через --db-url).")
        tsc = args.textsearch or tsc_env or "ru"
        engine = create_engine(db_url, pool_pre_ping=True, future=True)
        ensure_db(engine, tsc)
        inserted = upsert_products(engine, ndf)
        seed_synonyms(engine)
        print(f"Inserted/processed rows: {inserted}")
        print("Готово. Проверьте, что ваш поисковый сервис читает из таблицы products.")

if __name__ == "__main__":
    main()

# schema.sql (standalone)
schema_sql = r'''-- schema.sql — таблицы и индексы для ассистента продаж

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS unaccent;
-- опционально:
-- CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS products (
    id BIGSERIAL PRIMARY KEY,
    sku TEXT,
    name TEXT NOT NULL,
    category TEXT,
    unit TEXT DEFAULT 'шт',
    price_rub NUMERIC,
    thickness_mm NUMERIC,
    width_mm NUMERIC,
    length_mm NUMERIC,
    material TEXT,
    coating TEXT,
    profile_mark TEXT,
    attrs JSONB DEFAULT '{}'::jsonb,
    ts tsvector
);

CREATE TABLE IF NOT EXISTS product_synonyms (
    id BIGSERIAL PRIMARY KEY,
    term TEXT NOT NULL,
    norm TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_products_name_trgm ON products USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_products_ts     ON products USING gin (ts);

CREATE OR REPLACE FUNCTION set_products_ts() RETURNS trigger AS $$
BEGIN
  NEW.ts := to_tsvector(COALESCE(current_setting('app.textsearch_config', true), 'simple'), 
              unaccent(COALESCE(NEW.name,''))) ||
            to_tsvector(COALESCE(current_setting('app.textsearch_config', true), 'simple'),
              unaccent(COALESCE(NEW.category,'')));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_products_ts ON products;
CREATE TRIGGER trg_products_ts BEFORE INSERT OR UPDATE ON products
FOR EACH ROW EXECUTE FUNCTION set_products_ts();

-- Пример вспомогательной вьюхи с нормализацией синонимов для простых LIKE-поисков
CREATE OR REPLACE VIEW vw_products_search AS
SELECT p.*
FROM products p;'''