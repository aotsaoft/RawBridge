from fastapi import FastAPI, Request, Query
from fastapi.responses import JSONResponse
from pathlib import Path
import re
import time

app = FastAPI()

BASE_DIR = Path(__file__).resolve().parent
UPLOAD_DIR = BASE_DIR / "RECEIVED"
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

RAW_EXTS = {".arw", ".cr2", ".cr3", ".nef", ".raf", ".orf", ".rw2", ".dng", ".pef", ".srw"}
VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".mts", ".m2ts", ".avi", ".mkv"}

def safe_piece(value: str) -> str:
    value = value.strip().replace("\\", "/")
    value = re.sub(r'[<>:"|?*\x00-\x1f]', "_", value)
    value = value.replace("..", "_")
    return value

def unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    n = 1
    while True:
        candidate = path.with_name(f"{path.stem}_{n}{path.suffix}")
        if not candidate.exists():
            return candidate
        n += 1

@app.get("/health")
def health():
    return {"ok": True, "service": "RAW Bridge Receiver"}

@app.post("/upload-raw")
async def upload_raw(
    request: Request,
    event_name: str = Query("TEST"),
    relative_path: str = Query(""),
    filename: str = Query("upload.bin"),
):
    event = safe_piece(event_name)[:100] or "TEST"
    filename = Path(safe_piece(filename)).name or "upload.bin"
    relative = safe_piece(relative_path or filename)

    ext = Path(filename).suffix.lower()
    if ext in RAW_EXTS:
        category = "RAW"
    elif ext in VIDEO_EXTS:
        category = "VIDEO"
    else:
        category = "OTHER"

    parts = [p for p in relative.split("/") if p not in ("", ".", "..")]
    subdirs = parts[:-1]

    dest_dir = UPLOAD_DIR / event / category
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

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
