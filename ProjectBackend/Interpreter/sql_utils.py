# Shared helper for xcel/csv interpreters - loads tables into SQLite, describes the schema for the LLM, and runs read-only queries.
from pathlib import Path
import re
import sqlite3

import pandas as pd

DB_DIR = Path(__file__).resolve().parent.parent / "LocalStorage" / ".interpreted" / "sql"
SAMPLE_ROWS = 5
MAX_QUERY_ROWS = 200
FORBIDDEN_SQL = re.compile(r"\b(insert|update|delete|drop|alter|create|replace|attach|detach|pragma|vacuum|reindex)\b", re.IGNORECASE)


def clean_name(name: str, fallback: str = "table") -> str:
    cleaned = re.sub(r"\W+", "_", str(name)).strip("_").lower()
    if not cleaned:
        cleaned = fallback
    return f"t_{cleaned}" if cleaned[0].isdigit() else cleaned


def clean_columns(columns) -> list:
    seen, out = {}, []
    for i, col in enumerate(columns):
        name = clean_name(col, f"col_{i}")
        seen[name] = seen.get(name, 0) + 1
        out.append(name if seen[name] == 1 else f"{name}_{seen[name]}")
    return out


def build_database(frames: dict, db_name: str) -> Path:
    # frames: {table_name: DataFrame}. Rebuilt fresh each time so it never goes stale.
    DB_DIR.mkdir(parents=True, exist_ok=True)
    db_path = DB_DIR / f"{clean_name(db_name)}.sqlite"
    if db_path.exists():
        db_path.unlink()
    conn = sqlite3.connect(db_path)
    try:
        for table, df in frames.items():
            df = df.copy()
            df.columns = clean_columns(df.columns)
            df.to_sql(clean_name(table), conn, index=False, if_exists="replace")
        conn.commit()
    finally:
        conn.close()
    return db_path


def describe_database(db_path: Path) -> dict:
    conn = sqlite3.connect(db_path)
    info = {"db_path": str(db_path), "tables": []}
    try:
        for (table,) in conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall():
            cols = conn.execute(f'PRAGMA table_info("{table}")').fetchall()
            count = conn.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
            sample = conn.execute(f'SELECT * FROM "{table}" LIMIT {SAMPLE_ROWS}').fetchall()
            info["tables"].append({"name": table, "rows": count, "columns": [{"name": c[1], "type": c[2]} for c in cols], "sample": [list(r) for r in sample]})
    finally:
        conn.close()
    return info


def schema_text(info: dict) -> str:
    lines = [f"SQLite database: {info['db_path']}"]
    for t in info["tables"]:
        cols = ", ".join(f"{c['name']} {c['type']}" for c in t["columns"])
        lines.append(f"\nTABLE {t['name']} ({t['rows']} rows)\n  columns: {cols}\n  sample rows:")
        lines.extend(f"    {row}" for row in t["sample"])
    return "\n".join(lines)


def run_select(db_path, query: str) -> str:
    # read-only enforcement: single SELECT/WITH statement, keyword blocklist, and a read-only connection
    q = query.strip().rstrip(";")
    if ";" in q:
        return "ERROR: only a single SQL statement is allowed"
    if not re.match(r"^\s*(select|with)\b", q, re.IGNORECASE) or FORBIDDEN_SQL.search(q):
        return "ERROR: only read-only SELECT queries are allowed"
    db = Path(db_path)
    if not db.is_file():
        return f"ERROR: database not found: {db.name}"
    try:
        conn = sqlite3.connect(f"file:{db.as_posix()}?mode=ro", uri=True)
        df = pd.read_sql_query(q, conn)
        conn.close()
    except Exception as e:
        return f"ERROR: {e}"
    note = f"\n...[showing first {MAX_QUERY_ROWS} of {len(df)} rows]" if len(df) > MAX_QUERY_ROWS else ""
    return df.head(MAX_QUERY_ROWS).to_string(index=False) + note