# Prepares images (files OR base64-encoded strings) in the proper format for the vision LLM. No OCR - the vision model does the reading.
from pathlib import Path
import base64
import io
import re

from PIL import Image, ImageOps

from ProjectBackend.Interpreter import empty_result, error_result

KIND = "image"
MAX_SIDE = 1344                 # longest side sent to the vision model (keeps token cost sane)
OUTPUT_FORMAT = "JPEG"
JPEG_QUALITY = 90
DATA_URI = re.compile(r"^data:(image/[a-zA-Z0-9.+-]+);base64,(.+)$", re.DOTALL)


def _load_encoded(text: str):
    # accepts a full data URI or raw base64 and returns a PIL image
    text = text.strip()
    m = DATA_URI.match(text)
    raw = base64.b64decode(m.group(2) if m else re.sub(r"\s+", "", text), validate=False)
    return Image.open(io.BytesIO(raw))


def _normalise(img: Image.Image) -> Image.Image:
    img = ImageOps.exif_transpose(img)
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        background = Image.new("RGB", img.size, (255, 255, 255))
        background.paste(img, mask=img.split()[-1])
        img = background
    elif img.mode != "RGB":
        img = img.convert("RGB")
    if max(img.size) > MAX_SIDE:
        img.thumbnail((MAX_SIDE, MAX_SIDE), Image.LANCZOS)
    return img


def to_data_uri(img: Image.Image) -> str:
    buf = io.BytesIO()
    _normalise(img).save(buf, format=OUTPUT_FORMAT, quality=JPEG_QUALITY)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode("ascii")


def _is_existing_file(source) -> bool:
    if isinstance(source, Path):
        return source.is_file()
    if not isinstance(source, str) or source.lstrip().startswith("data:") or len(source) > 4096:
        return False
    try:
        return Path(source).is_file()
    except OSError:      # e.g. "File name too long" when the string is really base64
        return False


def prepare(source) -> dict:
    # source: a Path/str to an image file, OR a base64/data-URI string. Returns {"data_uri", "width", "height", "original_size"}
    if _is_existing_file(source):
        img = Image.open(source)
    else:
        img = _load_encoded(str(source))
    original = img.size
    norm = _normalise(img)
    return {"data_uri": to_data_uri(norm), "width": norm.size[0], "height": norm.size[1], "original_size": original}


def initialize(path, **options) -> dict:
    p = Path(path)
    try:
        if p.suffix.lower() in (".txt", ".b64", ".base64"):
            prepared = prepare(p.read_text(encoding="utf-8"))
            origin = "encoded image text file"
        else:
            prepared = prepare(p)
            origin = "image file"
    except Exception as e:
        return error_result(KIND, f"could not decode image: {e}")
    result = empty_result(KIND)
    result["images"] = [{"name": p.name, "path": str(p), "mime": "image/jpeg", "data_uri": prepared["data_uri"], "location": origin}]
    result["meta"] = {"width": prepared["width"], "height": prepared["height"], "original_size": prepared["original_size"]}
    result["summary"] = f"Image '{p.name}' ({prepared['original_size'][0]}x{prepared['original_size'][1]}) prepared for the vision model"
    result["text"] = "[Image content must be read by the vision model - call analyze_image]"
    return result
