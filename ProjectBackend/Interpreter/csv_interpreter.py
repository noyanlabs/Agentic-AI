# Reads a CSV/TSV, loads it into SQLite and gives the LLM the schema + properties so it can write SQL queries. Same idea as xcel_interpreter.
from pathlib import Path
import csv

import pandas as pd

from Interpreter import empty_result, error_result
from Interpreter.sql_utils import build_database, describe_database, schema_text

KIND = "csv"
ENCODINGS = ["utf-8", "utf-8-sig", "latin-1"]


def _detect_separator(path: Path) -> str:
    if path.suffix.lower() == ".tsv":
        return "\t"
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return csv.Sniffer().sniff(f.read(8192), delimiters=",;\t|").delimiter
    except Exception:
        return ","


def _read_any_encoding(path: Path, sep: str):
    last = None
    for enc in ENCODINGS:
        try:
            return pd.read_csv(path, sep=sep, encoding=enc, low_memory=False), enc
        except UnicodeDecodeError as e:
            last = e
    raise last


def initialize(path, **options) -> dict:
    p = Path(path)
    sep = _detect_separator(p)
    try:
        df, encoding = _read_any_encoding(p, sep)
    except Exception as e:
        return error_result(KIND, str(e))
    df = df.dropna(how="all").dropna(axis=1, how="all")
    if df.empty:
        return error_result(KIND, "file has no data")
    db_path = build_database({p.stem: df}, p.stem)
    info = describe_database(db_path)
    result = empty_result(KIND)
    result["sql"] = info
    result["text"] = schema_text(info)
    result["meta"] = {"separator": repr(sep), "encoding": encoding, "rows": len(df), "columns": len(df.columns), "database": str(db_path)}
    result["summary"] = f"CSV '{p.name}': {len(df)} rows x {len(df.columns)} columns. Loaded into SQLite - use query_sql with db '{db_path.name}'"
    return result
