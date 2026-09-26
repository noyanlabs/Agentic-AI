# Extracts frames from a video at equal intervals and prepares them for the vision model. No OCR, no audio transcription.
from pathlib import Path

import cv2
from PIL import Image

from ProjectBackend.Interpreter import empty_result, error_result
from ProjectBackend.Interpreter.image_and_encoded_image_interpreter import to_data_uri

KIND = "video"
DEFAULT_FRAMES = 8
MAX_FRAMES = 32


def _frame_indices(total: int, count: int) -> list:
    # equal spacing, sampled from the centre of each segment so we never grab the black first/last frame
    count = max(1, min(count, total))
    return [int((i + 0.5) * total / count) for i in range(count)]


def initialize(path, num_frames: int = DEFAULT_FRAMES, **options) -> dict:
    p = Path(path)
    num_frames = max(1, min(int(num_frames), MAX_FRAMES))
    cap = cv2.VideoCapture(str(p))
    if not cap.isOpened():
        return error_result(KIND, "could not open video")
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    fps = cap.get(cv2.CAP_PROP_FPS) or 0
    width, height = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    if total <= 0:
        cap.release()
        return error_result(KIND, "video has no readable frames")
    duration = total / fps if fps else 0
    result = empty_result(KIND)
    for idx in _frame_indices(total, num_frames):
        cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
        ok, frame = cap.read()
        if not ok:
            continue
        img = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        stamp = idx / fps if fps else 0
        result["images"].append({"name": f"{p.stem}_t{stamp:.1f}s.jpg", "path": str(p), "mime": "image/jpeg", "data_uri": to_data_uri(img), "location": f"t={stamp:.1f}s (frame {idx})"})
    cap.release()
    if not result["images"]:
        return error_result(KIND, "no frames could be extracted")
    result["meta"] = {"duration_s": round(duration, 2), "fps": round(fps, 2), "frames_total": total, "resolution": f"{width}x{height}", "frames_extracted": len(result["images"])}
    result["summary"] = f"Video '{p.name}': {duration:.1f}s, {width}x{height}, {len(result['images'])} frames extracted at equal intervals for the vision model"
    result["text"] = "[Video content must be read by the vision model - call analyze_video]"
    return result