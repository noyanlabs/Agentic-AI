# Reads a PDF: direct text + tables + embedded images. Scanned/image-only pages are rendered as images for the vision model (NO OCR).
from pathlib import Path
import hashlib

import pymupdf as fitz  # PyMuPDF

from Interpreter import empty_result, error_result

KIND = "pdf"
IMAGE_CACHE = Path(__file__).resolve().parent.parent / "LocalStorage" / ".interpreted" / "images"
SCANNED_PAGE_MIN_CHARS = 25      # a page with fewer characters than this is treated as a scan
RENDER_DPI = 110
MAX_IMAGES = 60
MIN_EMBEDDED_IMAGE_PX = 80


def _tables_on_page(page, page_no: int) -> list:
    out = []
    try:
        for t in page.find_tables().tables:
            rows = [[("" if c is None else str(c).strip()) for c in row] for row in t.extract()]
            if rows:
                out.append({"location": f"page {page_no}", "rows": rows})
    except Exception:
        pass
    return out


def _render_page(page, page_no: int, stem: str):
    IMAGE_CACHE.mkdir(parents=True, exist_ok=True)
    out = IMAGE_CACHE / f"{stem}_page{page_no}.png"
    page.get_pixmap(dpi=RENDER_DPI).save(str(out))
    return {"name": out.name, "path": str(out), "mime": "image/png", "location": f"page {page_no} (rendered - needs vision)"}


def _embedded_images(doc, page, page_no: int, stem: str, store: list):
    for img in page.get_images(full=True):
        if len(store) >= MAX_IMAGES:
            return
        try:
            info = doc.extract_image(img[0])
            if min(info["width"], info["height"]) < MIN_EMBEDDED_IMAGE_PX:
                continue
            digest = hashlib.md5(info["image"]).hexdigest()[:8]
            out = IMAGE_CACHE / f"{stem}_p{page_no}_{digest}.{info['ext']}"
            out.write_bytes(info["image"])
            store.append({"name": out.name, "path": str(out), "mime": f"image/{info['ext']}", "location": f"page {page_no}"})
        except Exception:
            continue


def initialize(path, page_range: tuple = None, **options) -> dict:
    p = Path(path)
    try:
        doc = fitz.open(str(p))
    except Exception as e:
        return error_result(KIND, str(e))
    if doc.needs_pass:
        return error_result(KIND, "PDF is password protected")
    result = empty_result(KIND)
    IMAGE_CACHE.mkdir(parents=True, exist_ok=True)
    blocks, scanned_pages = [], []
    for i, page in enumerate(doc, start=1):
        if page_range and not (page_range[0] <= i <= page_range[1]):
            continue
        text = page.get_text("text").strip()
        if len(text) < SCANNED_PAGE_MIN_CHARS:
            scanned_pages.append(i)
            if len(result["images"]) < MAX_IMAGES:
                result["images"].append(_render_page(page, i, p.stem))
            blocks.append(f"--- Page {i} ---\n[no extractable text - page rendered as an image for the vision model]")
            continue
        blocks.append(f"--- Page {i} ---\n{text}")
        result["tables"].extend(_tables_on_page(page, i))
        _embedded_images(doc, page, i, p.stem, result["images"])
    result["text"] = "\n\n".join(blocks)
    result["meta"] = {"pages": len(doc), "scanned_pages": scanned_pages, "tables": len(result["tables"]), "images": len(result["images"]), "title": (doc.metadata or {}).get("title", "")}
    note = f", {len(scanned_pages)} scanned page(s) need vision" if scanned_pages else ""
    result["summary"] = f"PDF '{p.name}': {len(doc)} pages, {len(result['tables'])} tables, {len(result['images'])} images{note}"
    doc.close()
    return result
