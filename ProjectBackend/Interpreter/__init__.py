# Interpreter package - every interpreter returns the SAME result shape so the central backend can treat them uniformly:
#   {"kind": "<type>", "ok": bool, "summary": str, "text": str, "tables": [...], "math": [...], "images": [{"name","path","mime"}], "sql": {...} | None, "meta": {...}, "error": str | None}
from pathlib import Path

EXTENSION_MAP = {
    ".pptx": "ppt_interpreter", ".ppt": "ppt_interpreter",
    ".docx": "docx_interpreter", ".doc": "docx_interpreter",
    ".xlsx": "xcel_interpreter", ".xlsm": "xcel_interpreter", ".xls": "xcel_interpreter",
    ".csv": "csv_interpreter", ".tsv": "csv_interpreter",
    ".pdf": "pdf_interpreter",
    ".zip": "zip_interpreter",
    ".png": "image_and_encoded_image_interpreter", ".jpg": "image_and_encoded_image_interpreter", ".jpeg": "image_and_encoded_image_interpreter",
    ".gif": "image_and_encoded_image_interpreter", ".bmp": "image_and_encoded_image_interpreter", ".webp": "image_and_encoded_image_interpreter",
    ".b64": "image_and_encoded_image_interpreter", ".base64": "image_and_encoded_image_interpreter",
    ".mp4": "video_interpreter", ".mov": "video_interpreter", ".avi": "video_interpreter", ".mkv": "video_interpreter", ".webm": "video_interpreter",
}
TEXT_EXTENSIONS = {".txt", ".md", ".py", ".json", ".yaml", ".yml", ".html", ".css", ".js", ".ts", ".xml", ".log", ".ini", ".toml", ".c", ".cpp", ".java", ".sql", ".sh", ".tex", ".dart", ".rs", ".go"}


def empty_result(kind: str) -> dict:
    return {"kind": kind, "ok": True, "summary": "", "text": "", "tables": [], "math": [], "images": [], "sql": None, "meta": {}, "error": None}


def error_result(kind: str, message: str) -> dict:
    r = empty_result(kind)
    r.update({"ok": False, "error": message, "summary": f"ERROR reading {kind}: {message}"})
    return r


def interpreter_for(path) -> str | None:
    return EXTENSION_MAP.get(Path(path).suffix.lower())


def initialize(path, **options) -> dict:
    # Single dispatcher: picks the interpreter from the file extension. Plain text files are handled inline.
    import importlib
    p = Path(path)
    if not p.is_file():
        return error_result("unknown", f"file not found: {p.name}")
    name = interpreter_for(p)
    if name:
        module = importlib.import_module(f"Interpreter.{name}")
        return module.initialize(p, **options)
    if p.suffix.lower() in TEXT_EXTENSIONS or p.suffix == "":
        try:
            text = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            return error_result("text", "file is not valid UTF-8 text")
        r = empty_result("text")
        r.update({"text": text, "summary": f"Text file {p.name}, {len(text)} chars", "meta": {"chars": len(text), "lines": text.count(chr(10)) + 1}})
        return r
    return error_result("unknown", f"no interpreter for '{p.suffix}' files")
