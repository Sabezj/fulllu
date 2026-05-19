# Writing a robust converter script to turn supplier XLS price lists into the app's normalized "Price List".
# The script will:
# - Read .xls/.xlsx (auto-detect sheets)
# - Auto-detect Russian column names: name, thickness, width, length, unit, price, sku
# - Normalize units, compute price_per_m2 when possible
# - Output: products.csv, products.jsonl, products.sql
# - Optional: insert into Postgres (DATABASE_URL) with --to-db
# - Optional: emit embeddings TODO hooks (left as stub to not hit external APIs here)
#
# Usage (Windows PowerShell examples):
#   python price_convert.py "21.08.2024_Прайсы_ Москва №7 (ЭБК) (1).xls" --sheet 0 --out-prefix out/moscow7 --to-db
#   $env:DATABASE_URL="postgres://postgres:postgres@localhost:5432/db"
#
# The produced files will be available to download from the sandbox path.

from pathlib import Path
import os
import re
import sys
import json
import argparse
from typing import Dict, Any, List, Optional

import pandas as pd

TEMPLATE_SQL = """
create extension if not exists pg_trgm;
create extension if not exists vector;

create table if not exists products (
    id serial primary key,
    sku text,
    name text not null,
    category text,
    thickness_mm numeric,
    width_mm numeric,
    length_mm numeric,
    unit text,
    price_rub numeric,           -- как в прайсе (за unit)
    price_rub_m2 numeric,        -- пересчитанная цена за м2, если возможно
    currency text default 'RUB',
    source_file text,
    source_sheet text,
    slug text,
    created_at timestamp default now(),
    updated_at timestamp default now()
);

create index if not exists idx_products_name_trgm on products using gin (name gin_trgm_ops);
create index if not exists idx_products_sku on products(sku);

-- Upsert template
-- insert into products(sku,name,category,thickness_mm,width_mm,length_mm,unit,price_rub,price_rub_m2,currency,source_file,source_sheet,slug)
-- values (...)
-- on conflict (sku) do update
-- set name=excluded.name, category=excluded.category, thickness_mm=excluded.thickness_mm,
--     width_mm=excluded.width_mm, length_mm=excluded.length_mm, unit=excluded.unit,
--     price_rub=excluded.price_rub, price_rub_m2=excluded.price_rub_m2,
--     currency=excluded.currency, source_file=excluded.source_file, source_sheet=excluded.source_sheet,
--     slug=excluded.slug, updated_at=now();
""".strip()


RUS_COLS = {
    # canonical_name: [variants...]
    "sku": ["артикул", "код", "код товара", "sku"],
    "name": ["наименование", "товар", "продукт", "позиция", "наименование товара", "описание"],
    "category": ["категория", "группа", "раздел"],
    "thickness": ["толщина", "толщина, мм", "толщина мм", "t, мм", "t мм"],
    "width": ["ширина", "ширина, мм", "ширина мм", "w, мм", "w мм"],
    "length": ["длина", "длина, мм", "длина мм", "l, мм", "l мм"],
    "unit": ["ед.изм", "ед изм", "единица", "единица измерения", "unit"],
    "price": ["цена", "цена, руб", "розничная цена", "опт", "стоимость", "price"],
    "currency": ["валюта", "currency"],
}

UNIT_ALIASES = {
    "шт": ["шт", "штука", "штуки", "штук", "pcs", "pc"],
    "м2": ["м2", "м^2", "кв.м", "кв. м", "кв.м.", "sqm", "m2", "sq m", "square meter", "квадратный метр"],
    "м": ["м", "метр", "метры", "meter", "m"],
    "пог.м": ["пог.м", "погонный метр", "пог м", "п.м", "rm"],
}

def normalize_unit(u: Optional[str]) -> Optional[str]:
    if not u or not isinstance(u, str):
        return None
    u0 = u.strip().lower().replace(".", "").replace("  ", " ")
    for canon, variants in UNIT_ALIASES.items():
        for v in variants:
            vv = v.replace(".", "").lower()
            if u0 == vv:
                return canon
    # heuristic
    if "шт" in u0:
        return "шт"
    if "кв" in u0 or "м2" in u0 or "sq" in u0:
        return "м2"
    if "пог" in u0:
        return "пог.м"
    if u0 in {"m", "метр", "метры", "м"}:
        return "м"
    return u.strip()

def to_mm(val: Any) -> Optional[float]:
    if val is None or (isinstance(val, float) and pd.isna(val)):
        return None
    if isinstance(val, (int, float)):
        return float(val)
    s = str(val).strip().lower()
    # catch "1.5 мм" / "1,5 мм"
    s = s.replace(",", ".")
    m = re.search(r"(\d+(?:\.\d+)?)\s*(мм|cm|см|m|м)?", s)
    if not m:
        return None
    num = float(m.group(1))
    unit = m.group(2) or "мм"
    if unit in ("мм",):
        return num
    if unit in ("см", "cm"):
        return num * 10.0
    if unit in ("м", "m"):
        return num * 1000.0
    return num

def price_to_float(x: Any) -> Optional[float]:
    if x is None or (isinstance(x, float) and pd.isna(x)):
        return None
    s = str(x).strip()
    s = s.replace(" ", "").replace("\u00A0", "").replace(",", ".")
    s = re.sub(r"[^\d\.]", "", s)
    try:
        return float(s)
    except:
        return None

def slugify(name: str) -> str:
    s = name.lower()
    s = re.sub(r"[^a-z0-9а-яё\- ]", " ", s)
    s = re.sub(r"\s+", "-", s).strip("-")
    return s

def detect_columns(df: pd.DataFrame) -> Dict[str, str]:
    cols = {c: str(c).strip().lower() for c in df.columns}
    mapping: Dict[str, str] = {}
    used = set()
    for canon, variants in RUS_COLS.items():
        for col, low in cols.items():
            if col in used: 
                continue
            if low == canon:
                mapping[canon] = col
                used.add(col)
                break
        if canon not in mapping:
            for v in RUS_COLS[canon]:
                for col, low in cols.items():
                    if col in used:
                        continue
                    if v == low or v in low:
                        mapping[canon] = col
                        used.add(col)
                        break
                if canon in mapping:
                    break
    return mapping

def compute_price_per_m2(unit: Optional[str], price: Optional[float],
                         width_mm: Optional[float], length_mm: Optional[float]) -> Optional[float]:
    if price is None:
        return None
    u = normalize_unit(unit)
    if u == "м2":
        return price
    if u == "шт" and width_mm and length_mm and width_mm > 0 and length_mm > 0:
        area_m2 = (width_mm / 1000.0) * (length_mm / 1000.0)
        if area_m2 > 0:
            return round(price / area_m2, 2)
    if u == "пог.м" and width_mm and width_mm > 0:
        width_m = width_mm / 1000.0
        return round(price / width_m, 2)
    if u == "м":
        # цена за метр без ширины — не пересчитываем
        return None
    return None

def infer_category(name: str) -> Optional[str]:
    n = name.lower()
    if "профнастил" in n or re.search(r"\bс-?\d+\b", n):
        return "Профнастил"
    if "оцинк" in n or "оцинкованный" in n:
        return "Оцинкованные листы"
    if "лист" in n and "сталь" in n:
        return "Стальные листы"
    if "арматур" in n:
        return "Арматура"
    return None

def parse_args():
    ap = argparse.ArgumentParser(description="Convert supplier XLS price list to app normalized format")
    ap.add_argument("input", help="Path to .xls/.xlsx")
    ap.add_argument("--sheet", help="Sheet index or name", default=None)
    ap.add_argument("--out-prefix", help="Output prefix (without extension)", default="products")
    ap.add_argument("--to-db", action="store_true", help="Insert into Postgres using DATABASE_URL")
    return ap.parse_args()

def read_excel(path: str, sheet=None) -> pd.DataFrame:
    ext = Path(path).suffix.lower()
    if ext == ".xls":
        try:
            return pd.read_excel(path, sheet_name=sheet, engine="xlrd")
        except Exception:
            # fallback to default engine
            return pd.read_excel(path, sheet_name=sheet)
    else:
        return pd.read_excel(path, sheet_name=sheet)

def main():
    args = parse_args()
    src = args.input
    df = read_excel(src, sheet=args.sheet)
    # If multi-sheet returns dict
    if isinstance(df, dict):
        # pick first sheet if name/index not specified
        key = next(iter(df.keys()))
        df = df[key]
        sheet_name = str(key)
    else:
        sheet_name = str(args.sheet) if args.sheet is not None else "0"

    # drop fully empty cols/rows
    df = df.dropna(how="all")
    df = df.loc[:, ~df.columns.duplicated()]

    colmap = detect_columns(df)
    # Build records
    rows: List[Dict[str, Any]] = []
    for _, r in df.iterrows():
        name = None
        for k in ("name",):
            col = colmap.get(k)
            if col:
                name = r.get(col)
                break
        if not isinstance(name, str) or not name.strip():
            continue
        name = re.sub(r"\s+", " ", name).strip()

        sku = None
        if colmap.get("sku"):
            sku_val = r.get(colmap["sku"])
            if pd.notna(sku_val):
                sku = str(sku_val).strip()

        thickness = to_mm(r.get(colmap.get("thickness"))) if colmap.get("thickness") else None
        width = to_mm(r.get(colmap.get("width"))) if colmap.get("width") else None
        length = to_mm(r.get(colmap.get("length"))) if colmap.get("length") else None

        unit_raw = r.get(colmap.get("unit")) if colmap.get("unit") else None
        unit = normalize_unit(unit_raw) if unit_raw is not None else None

        price_raw = r.get(colmap.get("price")) if colmap.get("price") else None
        price = price_to_float(price_raw)

        currency = None
        if colmap.get("currency"):
            c0 = r.get(colmap["currency"])
            if pd.notna(c0):
                currency = str(c0).strip().upper()
        if not currency:
            currency = "RUB"

        category = None
        if colmap.get("category"):
            cat = r.get(colmap["category"])
            if isinstance(cat, str) and cat.strip():
                category = cat.strip()
        if not category:
            category = infer_category(name)

        price_m2 = compute_price_per_m2(unit, price, width, length)

        row = {
            "sku": sku,
            "name": name,
            "category": category,
            "thickness_mm": thickness,
            "width_mm": width,
            "length_mm": length,
            "unit": unit,
            "price_rub": price,
            "price_rub_m2": price_m2,
            "currency": currency,
            "source_file": Path(src).name,
            "source_sheet": sheet_name,
            "slug": slugify(name),
        }
        rows.append(row)

    out_prefix = Path(args.out_prefix)
    out_prefix.parent.mkdir(parents=True, exist_ok=True)

    # CSV
    csv_path = f"{out_prefix}.csv"
    pd.DataFrame(rows).to_csv(csv_path, index=False, encoding="utf-8-sig")

    # JSONL
    jsonl_path = f"{out_prefix}.jsonl"
    with open(jsonl_path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")

    # SQL
    sql_path = f"{out_prefix}.sql"
    with open(sql_path, "w", encoding="utf-8") as f:
        f.write(TEMPLATE_SQL + "\n\n")
        for row in rows:
            columns = [
                "sku","name","category","thickness_mm","width_mm","length_mm",
                "unit","price_rub","price_rub_m2","currency","source_file","source_sheet","slug"
            ]
            values = []
            for c in columns:
                v = row.get(c)
                if v is None or (isinstance(v, float) and pd.isna(v)):
                    values.append("NULL")
                elif isinstance(v, (int, float)):
                    values.append(str(v))
                else:
                    val = str(v).replace("'", "''")
                    values.append(f"'{val}'")
            f.write(
                "insert into products(" + ",".join(columns) + ") values (" + ",".join(values) + ");\n"
            )

    # Optional: insert into DB
    if args.to_db:
        url = os.getenv("DATABASE_URL")
        if not url:
            print("WARN: --to-db provided but DATABASE_URL not set. Skipping DB insert.", file=sys.stderr)
        else:
            try:
                from sqlalchemy import create_engine, text
                engine = create_engine(url)
                with engine.begin() as conn:
                    # Ensure schema
                    for stmt in TEMPLATE_SQL.split(";"):
                        s = stmt.strip()
                        if s:
                            conn.execute(text(s))
                    # Insert rows
                    for row in rows:
                        conn.execute(text("""
                            insert into products
                            (sku,name,category,thickness_mm,width_mm,length_mm,unit,price_rub,price_rub_m2,currency,source_file,source_sheet,slug)
                            values (:sku,:name,:category,:thickness_mm,:width_mm,:length_mm,:unit,:price_rub,:price_rub_m2,:currency,:source_file,:source_sheet,:slug)
                        """), row)
                print(f"Inserted {len(rows)} rows into products")
            except Exception as e:
                print(f"ERROR: DB insert failed: {e}", file=sys.stderr)

    print(f"Done. Wrote:\n - {csv_path}\n - {jsonl_path}\n - {sql_path}")
