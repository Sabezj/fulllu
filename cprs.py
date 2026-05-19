
from __future__ import annotations
from pathlib import Path
import os
import re
import sys
import json
import argparse
from typing import Dict, Any, List, Optional, Union

import pandas as pd

TEMPLATE_SQL = (
    """
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
"""
).strip()

RUS_COLS: Dict[str, List[str]] = {
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

UNIT_ALIASES: Dict[str, List[str]] = {
    "шт": ["шт", "штука", "штуки", "штук", "pcs", "pc"],
    "м2": ["м2", "м^2", "кв.м", "кв. м", "кв.м.", "sqm", "m2", "sq m", "square meter", "квадратный метр"],
    "м":  ["м", "метр", "метры", "meter", "m"],
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
    s = str(val).strip().lower().replace(",", ".")
    m = re.search(r"(\\d+(?:\\.\\d+)?)\\s*(мм|cm|см|m|м)?", s)
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
    s = s.replace(" ", "").replace("\\u00A0", "").replace(",", ".")
    s = re.sub(r"[^\\d\\.]", "", s)
    try:
        return float(s)
    except Exception:
        return None

def slugify(name: str) -> str:
    s = name.lower()
    s = re.sub(r"[^a-z0-9а-яё\\- ]", " ", s)
    s = re.sub(r"\\s+", "-", s).strip("-")
    return s

def detect_columns(df: pd.DataFrame) -> Dict[str, str]:
    cols = {c: str(c).strip().lower() for c in df.columns}
    mapping: Dict[str, str] = {}
    used = set()
    for canon, variants in RUS_COLS.items():
        # точное совпадение с каноническим ключом
        for col, low in cols.items():
            if col in used:
                continue
            if low == canon:
                mapping[canon] = col
                used.add(col)
                break
        if canon not in mapping:
            # поиск по вариантам
            for v in variants:
                vlow = v.lower()
                for col, low in cols.items():
                    if col in used:
                        continue
                    if vlow == low or vlow in low:
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
    # u == "м" или иные — без ширины нельзя точно в м2
    return None

def infer_category(name: str) -> Optional[str]:
    n = name.lower()
    if "профнастил" in n or re.search(r"\\bс-?\\d+\\b", n):
        return "Профнастил"
    if "оцинк" in n or "оцинкованный" in n:
        return "Оцинкованные листы"
    if "лист" in n and "сталь" in n:
        return "Стальные листы"
    if "арматур" in n:
        return "Арматура"
    return None

def read_excel(path: str, sheet: Optional[Union[int,str]] = None) -> Union[pd.DataFrame, Dict[str, pd.DataFrame]]:
    ext = Path(path).suffix.lower()
    if ext == ".xls":
        # xlrd поддерживает только старые .xls
        try:
            return pd.read_excel(path, sheet_name=sheet, engine="xlrd")
        except Exception:
            return pd.read_excel(path, sheet_name=sheet)
    # .xlsx — openpyxl по умолчанию
    return pd.read_excel(path, sheet_name=sheet)

def to_records(df: pd.DataFrame, src_file: str, sheet_name: str) -> List[Dict[str, Any]]:
    # убрать пустое
    df = df.dropna(how="all")
    df = df.loc[:, ~df.columns.duplicated()]

    colmap = detect_columns(df)
    rows: List[Dict[str, Any]] = []

    for _, r in df.iterrows():
        name = None
        if colmap.get("name"):
            name = r.get(colmap["name"])  # type: ignore
        if not isinstance(name, str) or not name.strip():
            continue
        name = re.sub(r"\\s+", " ", name).strip()

        sku = None
        if colmap.get("sku"):
            sku_val = r.get(colmap["sku"])  # type: ignore
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
            c0 = r.get(colmap["currency"])  # type: ignore
            if pd.notna(c0):
                currency = str(c0).strip().upper()
        if not currency:
            currency = "RUB"

        category = None
        if colmap.get("category"):
            cat = r.get(colmap["category"])  # type: ignore
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
            "source_file": Path(src_file).name,
            "source_sheet": sheet_name,
            "slug": slugify(name),
        }
        rows.append(row)
    return rows

def write_outputs(rows: List[Dict[str, Any]], out_prefix: Path) -> Dict[str, str]:
    out_prefix.parent.mkdir(parents=True, exist_ok=True)

    csv_path = f"{out_prefix}.csv"
    jsonl_path = f"{out_prefix}.jsonl"
    sql_path = f"{out_prefix}.sql"

    pd.DataFrame(rows).to_csv(csv_path, index=False, encoding="utf-8-sig")

    with open(jsonl_path, "w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\\n")

    with open(sql_path, "w", encoding="utf-8") as f:
        f.write(TEMPLATE_SQL + "\\n\\n")
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
                "insert into products(" + ",".join(columns) + ") values (" + ",".join(values) + ");\\n"
            )

    return {"csv": csv_path, "jsonl": jsonl_path, "sql": sql_path}

def insert_into_db(rows: List[Dict[str, Any]]):
    url = os.getenv("DATABASE_URL")
    if not url:
        print("WARN: --to-db указан, но DATABASE_URL не задан. Пропускаю вставку в БД.", file=sys.stderr)
        return
    try:
        from sqlalchemy import create_engine, text
    except Exception as e:
        print(f"ERROR: SQLAlchemy не установлен: {e}", file=sys.stderr)
        return

    engine = create_engine("postgresql://postgres:postgres@localhost:5432/db")
    with engine.begin() as conn:
        # schema
        for stmt in TEMPLATE_SQL.split(";"):
            s = stmt.strip()
            if s:
                conn.execute(text(s))
        # bulk insert
        for row in rows:
            conn.execute(text(
                """
                insert into products
                (sku,name,category,thickness_mm,width_mm,length_mm,unit,price_rub,price_rub_m2,currency,source_file,source_sheet,slug)
                values (:sku,:name,:category,:thickness_mm,:width_mm,:length_mm,:unit,:price_rub,:price_rub_m2,:currency,:source_file,:source_sheet,:slug)
                """
            ), row)

    print(f"Inserted {len(rows)} rows into products")

def parse_args():
    ap = argparse.ArgumentParser(description="Convert supplier XLS/XLSX price list to normalized format and load into Postgres")
    ap.add_argument("input", help="Path to .xls/.xlsx")
    ap.add_argument("--sheet", help="Sheet index or name", default=None)
    ap.add_argument("--out-prefix", help="Output prefix (without extension)", default="products")
    ap.add_argument("--to-db", action="store_true", help="Insert into Postgres using DATABASE_URL")
    return ap.parse_args()

def main():
    args = parse_args()
    src = args.input
    df = read_excel(src, sheet=args.sheet)

    all_rows: List[Dict[str, Any]] = []

    if isinstance(df, dict):
        # несколько листов
        for key, dfx in df.items():
            sheet_name = str(key)
            rows = to_records(dfx, src, sheet_name)
            all_rows.extend(rows)
    else:
        sheet_name = str(args.sheet) if args.sheet is not None else "0"
        all_rows = to_records(df, src, sheet_name)

    outputs = write_outputs(all_rows, Path(args.out_prefix))

    if args.to_db:
        insert_into_db(all_rows)

    print("Done. Wrote:")
    for k, v in outputs.items():
        print(f" - {v}")

if __name__ == "__main__":
    main()
