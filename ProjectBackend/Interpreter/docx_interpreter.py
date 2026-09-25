# Reads a .docx and returns text (in true document order), tables, math (LaTeX) and embedded images for the LLM.
from pathlib import Path
import hashlib

from docx import Document
from docx.table import Table
from docx.text.paragraph import Paragraph

from Interpreter import empty_result, error_result
from Interpreter.math_utils import find_math

KIND = "docx"
IMAGE_CACHE = Path(__file__).resolve().parent.parent / "LocalStorage" / ".interpreted" / "images"
W_NS = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
MAX_IMAGES = 60


def _paragraph_text(par: Paragraph, result: dict, order_index: int) -> str:
    math_here = find_math(par._element)
    for expr in math_here:
        result["math"].append({"location": f"block {order_index}", "latex": expr})
    text = par.text.strip()
    style = par.style.name if par.style is not None else ""
    if style.startswith("Heading"):
        level = "".join(ch for ch in style if ch.isdigit()) or "1"
        text = "#" * int(level) + " " + text
    if math_here:
        text = (text + " " + " ".join(f"$${m}$$" for m in math_here)).strip()
    return text


def _extract_images(doc, stem: str, result: dict):
    IMAGE_CACHE.mkdir(parents=True, exist_ok=True)
    for rel in doc.part.rels.values():
        if "image" not in rel.reltype or len(result["images"]) >= MAX_IMAGES:
            continue
        try:
            blob = rel.target_part.blob
            ext = Path(rel.target_part.partname).suffix.lstrip(".") or "png"
            digest = hashlib.md5(blob).hexdigest()[:8]
            out = IMAGE_CACHE / f"{stem}_{digest}.{ext}"
            out.write_bytes(blob)
            result["images"].append({"name": out.name, "path": str(out), "mime": f"image/{ext}", "location": "document"})
        except Exception:
            continue


def initialize(path, **options) -> dict:
    p = Path(path)
    if p.suffix.lower() == ".doc":
        return error_result(KIND, "legacy .doc is not supported; please convert to .docx")
    try:
        doc = Document(str(p))
    except Exception as e:
        return error_result(KIND, str(e))
    result = empty_result(KIND)
    lines = []
    for i, child in enumerate(doc.element.body.iterchildren()):
        if child.tag == f"{W_NS}p":
            line = _paragraph_text(Paragraph(child, doc), result, i)
            if line:
                lines.append(line)
        elif child.tag == f"{W_NS}tbl":
            rows = [[c.text.strip() for c in row.cells] for row in Table(child, doc).rows]
            result["tables"].append({"location": f"block {i}", "rows": rows})
            lines.append(f"[TABLE {len(result['tables'])}: {len(rows)} rows x {len(rows[0]) if rows else 0} cols]")
    _extract_images(doc, p.stem, result)
    result["text"] = "\n\n".join(lines)
    result["meta"] = {"paragraphs": len(lines), "tables": len(result["tables"]), "math": len(result["math"]), "images": len(result["images"])}
    result["summary"] = f"Word document '{p.name}': {len(lines)} blocks, {len(result['tables'])} tables, {len(result['math'])} equations, {len(result['images'])} images"
    return result