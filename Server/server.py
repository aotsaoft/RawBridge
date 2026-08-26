from fastapi import FastAPI, Request, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from pathlib import Path
from datetime import datetime, timezone
import json
import re
import time

app = FastAPI()

BASE_DIR = Path(__file__).resolve().parent
UPLOAD_DIR = BASE_DIR / "RECEIVED"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

RAW_EXTS = {
    ".arw", ".cr2", ".cr3", ".nef", ".raf", ".orf", ".rw2",
    ".dng", ".pef", ".srw", ".3fr", ".erf", ".kdc", ".mos",
    ".mrw", ".nrw", ".raw", ".rwl", ".x3f"
}

PHOTO_EXTS = {
    ".jpg", ".jpeg", ".heic", ".heif", ".png",
    ".tif", ".tiff", ".webp"
}

VIDEO_EXTS = {
    ".mp4", ".mov", ".m4v", ".mts", ".m2ts",
    ".avi", ".mkv", ".3gp"
}


class EventMeta(BaseModel):
    event_name: str
    rough_content: str = ""
    selected_extensions: list[str] = []
    expected_file_count: int = 0
    expected_bytes: int = 0


class EventComplete(BaseModel):
    event_name: str
    selected_extensions: list[str] = []
    file_count: int = 0
    total_bytes: int = 0


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def safe_piece(value: str) -> str:
    value = value.strip().replace("\\", "/")
    value = re.sub(r'[<>:"|?*\x00-\x1f]', "_", value)
    value = value.replace("..", "_")
    return value


def safe_event_name(value: str) -> str:
    value = safe_piece(value).replace("/", "_")
    return value[:100] or "TEST"


def unique_path(path: Path) -> Path:
    if not path.exists():
        return path

    n = 1
    while True:
        candidate = path.with_name(f"{path.stem}_{n}{path.suffix}")
        if not candidate.exists():
            return candidate
        n += 1


def event_root(event_name: str) -> Path:
    root = UPLOAD_DIR / safe_event_name(event_name)
    root.mkdir(parents=True, exist_ok=True)
    return root


def destination_base(root: Path, filename: str) -> Path:
    ext = Path(filename).suffix.lower()

    if ext in RAW_EXTS:
        return root / "PHOTO" / "RAW"

    if ext in {".jpg", ".jpeg"}:
        return root / "PHOTO" / "JPG"

    if ext in PHOTO_EXTS:
        return root / "PHOTO" / ext.lstrip(".").upper()

    if ext in VIDEO_EXTS:
        return root / "VIDEO" / ext.lstrip(".").upper()

    label = ext.lstrip(".").upper() or "NO_EXT"
    return root / "OTHER" / label


@app.get("/health")
def health():
    return {
        "ok": True,
        "service": "RAW Bridge Receiver",
        "version": "1.2"
    }


@app.post("/event-meta")
def save_event_meta(meta: EventMeta):
    root = event_root(meta.event_name)
    event_dir = root / "EVENT"
    event_dir.mkdir(parents=True, exist_ok=True)

    payload = {
        "event_name": meta.event_name,
        "rough_content": meta.rough_content,
        "selected_extensions": [
            x.lower().lstrip(".") for x in meta.selected_extensions
        ],
        "expected_file_count": meta.expected_file_count,
        "expected_bytes": meta.expected_bytes,
        "received_at": now_iso(),
        "status": "uploading"
    }

    with (event_dir / "event.json").open("w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)

    return {"ok": True, "saved_to": str(event_dir / "event.json")}


@app.post("/upload-file")
@app.post("/upload-raw")
async def upload_file(
    request: Request,
    event_name: str = Query("TEST"),
    relative_path: str = Query(""),
    filename: str = Query("upload.bin"),
):
    root = event_root(event_name)
    filename = Path(safe_piece(filename)).name or "upload.bin"
    relative = safe_piece(relative_path or filename)

    parts = [p for p in relative.split("/") if p not in ("", ".", "..")]
    subdirs = parts[:-1]

    dest_dir = destination_base(root, filename)
    for part in subdirs:
        dest_dir = dest_dir / safe_piece(part)[:120]
    dest_dir.mkdir(parents=True, exist_ok=True)

    final_path = unique_path(dest_dir / filename)
    temp_path = final_path.with_suffix(final_path.suffix + ".part")

    started = time.perf_counter()
    total = 0

    try:
        with temp_path.open("wb") as f:
            async for chunk in request.stream():
                if not chunk:
                    continue
                f.write(chunk)
                total += len(chunk)

        temp_path.replace(final_path)

    except Exception:
        if temp_path.exists():
            temp_path.unlink(missing_ok=True)
        raise

    elapsed = max(time.perf_counter() - started, 0.001)

    return JSONResponse({
        "ok": True,
        "bytes": total,
        "seconds": round(elapsed, 3),
        "saved_to": str(final_path)
    })


@app.post("/complete-event")
def complete_event(info: EventComplete):
    root = event_root(info.event_name)
    event_dir = root / "EVENT"
    event_dir.mkdir(parents=True, exist_ok=True)

    completion = {
        "event_name": info.event_name,
        "selected_extensions": [
            x.lower().lstrip(".") for x in info.selected_extensions
        ],
        "file_count": info.file_count,
        "total_bytes": info.total_bytes,
        "completed_at": now_iso(),
        "status": "complete"
    }

    marker = event_dir / "UPLOAD_COMPLETE.json"
    with marker.open("w", encoding="utf-8") as f:
        json.dump(completion, f, ensure_ascii=False, indent=2)

    # Also update event.json status if it exists.
    meta_path = event_dir / "event.json"
    if meta_path.exists():
        try:
            current = json.loads(meta_path.read_text(encoding="utf-8"))
            current["status"] = "complete"
            current["completed_at"] = completion["completed_at"]
            current["actual_file_count"] = info.file_count
            current["actual_bytes"] = info.total_bytes
            meta_path.write_text(
                json.dumps(current, ensure_ascii=False, indent=2),
                encoding="utf-8"
            )
        except Exception:
            pass

    return {"ok": True, "marker": str(marker)}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
