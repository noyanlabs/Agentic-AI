# Extracts a zip safely, then reads every file inside through the matching interpreter.
from pathlib import Path
import zipfile
import importlib

from ProjectBackend.Interpreter import empty_result, error_result, interpreter_for, TEXT_EXTENSIONS

KIND = "zip"
EXTRACT_ROOT = Path(__file__).resolve().parent.parent / "LocalStorage" / ".interpreted" / "unzipped"
MAX_TOTAL_BYTES = 500 * 1024 * 1024    # zip-bomb guard: total uncompressed size
MAX_FILES = 2000
MAX_DEPTH = 3                           # nested zip levels
MAX_INNER_TEXT = 3000                   # chars of each inner file kept in the combined text
MAX_RATIO = 200                         # compression ratio above this is suspicious


def _safe_extract(zf: zipfile.ZipFile, target: Path):
    target.mkdir(parents=True, exist_ok=True)
    infos = zf.infolist()
    if len(infos) > MAX_FILES:
        raise ValueError(f"zip has {len(infos)} entries (limit {MAX_FILES})")
    total = sum(i.file_size for i in infos)
    packed = sum(i.compress_size for i in infos) or 1
    if total > MAX_TOTAL_BYTES:
        raise ValueError(f"uncompressed size {total // (1024 * 1024)} MB exceeds limit")
    if total / packed > MAX_RATIO and total > 50 * 1024 * 1024:
        raise ValueError("suspicious compression ratio (possible zip bomb)")
    root = target.resolve()
    for info in infos:
        dest = (target / info.filename).resolve()
        if dest != root and root not in dest.parents:
            raise ValueError(f"unsafe path in zip (zip-slip): {info.filename}")
    zf.extractall(target)


def _read_inner(file: Path, depth: int, options: dict) -> dict:
    if file.suffix.lower() == ".zip":
        return initialize(file, _depth=depth + 1, **options)
    name = interpreter_for(file)
    if name:
        return importlib.import_module(f"ProjectBackend.Interpreter.{name}").initialize(file, **options)
    if file.suffix.lower() in TEXT_EXTENSIONS:
        try:
            r = empty_result("text")
            r["text"] = file.read_text(encoding="utf-8")
            r["summary"] = f"Text file {file.name}"
            return r
        except UnicodeDecodeError:
            pass
    return error_result("unknown", "unsupported file type")


def initialize(path, _depth: int = 0, **options) -> dict:
    p = Path(path)
    if _depth >= MAX_DEPTH:
        return error_result(KIND, f"nested zips deeper than {MAX_DEPTH} levels")
    try:
        with zipfile.ZipFile(p) as zf:
            target = EXTRACT_ROOT / f"{p.stem}_{abs(hash(str(p))) % 10**6}"
            _safe_extract(zf, target)
    except Exception as e:
        return error_result(KIND, str(e))
    result = empty_result(KIND)
    listing, blocks, skipped = [], [], []
    for f in sorted(x for x in target.rglob("*") if x.is_file()):
        rel = f.relative_to(target).as_posix()
        inner = _read_inner(f, _depth, options)
        if not inner["ok"]:
            skipped.append(f"{rel} ({inner['error']})")
            continue
        listing.append(f"{rel}: {inner['summary']}")
        text = inner["text"][:MAX_INNER_TEXT] + ("\n...[truncated]" if len(inner["text"]) > MAX_INNER_TEXT else "")
        blocks.append(f"=== {rel} ({inner['kind']}) ===\n{text}")
        result["tables"].extend({**t, "location": f"{rel} / {t['location']}"} for t in inner["tables"])
        result["math"].extend({**m, "location": f"{rel} / {m['location']}"} for m in inner["math"])
        result["images"].extend(inner["images"])
        if inner["sql"]:
            result["sql"] = result["sql"] or {"tables": []}
            result["sql"]["tables"].extend(inner["sql"]["tables"])
    result["text"] = "CONTENTS:\n" + "\n".join(listing) + ("\n\nSKIPPED:\n" + "\n".join(skipped) if skipped else "") + "\n\n" + "\n\n".join(blocks)
    result["meta"] = {"files_read": len(listing), "skipped": skipped, "extracted_to": str(target)}
    result["summary"] = f"Zip '{p.name}': {len(listing)} files read, {len(skipped)} skipped"
    return result