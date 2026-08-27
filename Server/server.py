from fastapi import FastAPI, Request, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from pathlib import Path
from datetime import datetime, timezone
from starlette.requests import ClientDisconnect
import asyncio
import json
import re
import time
import uuid

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

# Serialize final rename + job manifest update.
finalize_lock = asyncio.Lock()


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


def event_dir(root: Path) -> Path:
    directory = root / "EVENT"
    directory.mkdir(parents=True, exist_ok=True)
    return directory


def jobs_path(root: Path) -> Path:
    return event_dir(root) / "received_jobs.json"


def load_jobs(root: Path) -> dict:
    path = jobs_path(root)

    if not path.exists():
        return {}

    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
        return obj if isinstance(obj, dict) else {}
    except Exception:
        return {}


def save_jobs(root: Path, jobs: dict) -> None:
    path = jobs_path(root)
    path.write_text(
        json.dumps(jobs, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )


def load_event_meta(root: Path) -> dict:
    path = event_dir(root) / "event.json"

    if not path.exists():
        return {}

    try:
        obj = json.loads(path.read_text(encoding="utf-8"))
        return obj if isinstance(obj, dict) else {}
    except Exception:
        return {}


def write_upload_complete_from_jobs(root: Path, jobs: dict) -> Path | None:
    meta = load_event_meta(root)
    expected = int(meta.get("expected_file_count") or 0)

    if expected <= 0 or len(jobs) < expected:
        return None

    event_name = str(meta.get("event_name") or root.name)

    selected_extensions = [
        str(x).lower().lstrip(".")
        for x in meta.get("selected_extensions", [])
    ]

    actual_bytes = sum(
        int(info.get("bytes") or 0)
        for info in jobs.values()
        if isinstance(info, dict)
    )

    completed_at = now_iso()

    completion = {
        "event_name": event_name,
        "selected_extensions": selected_extensions,
        "file_count": len(jobs),
        "total_bytes": actual_bytes,
        "completed_at": completed_at,
        "status": "complete",
        "auto_completed_by_server": True,
    }

    marker = event_dir(root) / "UPLOAD_COMPLETE.json"
    marker.write_text(
        json.dumps(completion, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )

    meta["status"] = "complete"
    meta["completed_at"] = completed_at
    meta["actual_file_count"] = len(jobs)
    meta["actual_bytes"] = actual_bytes

    (event_dir(root) / "event.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )

    return marker


def lookup_received_job(root: Path, job_id: str) -> dict | None:
    if not job_id:
        return None

    jobs = load_jobs(root)
    info = jobs.get(job_id)
    return info if isinstance(info, dict) else None


async def safe_delete(path: Path, attempts: int = 8) -> None:
    if not path.exists():
        return

    for i in range(attempts):
        try:
            path.unlink(missing_ok=True)
            return
        except PermissionError:
            await asyncio.sleep(0.15 * (i + 1))
        except FileNotFoundError:
            return
        except Exception:
            return


@app.get("/health")
def health():
    return {
        "ok": True,
        "service": "RAW Bridge Receiver",
        "version": "1.5"
    }


@app.post("/event-meta")
def save_event_meta(meta: EventMeta):
    root = event_root(meta.event_name)
    directory = event_dir(root)

    # Một session mới cùng tên sự kiện phải có manifest riêng.
    # Nếu event cũ đã complete, reset manifest nhận job.
    old_meta = load_event_meta(root)

    if old_meta.get("status") == "complete":
        try:
            jobs_path(root).unlink(missing_ok=True)
        except Exception:
            pass

        try:
            (directory / "UPLOAD_COMPLETE.json").unlink(missing_ok=True)
        except Exception:
            pass

    payload = {
        "event_name": meta.event_name,
        "rough_content": meta.rough_content,
        "selected_extensions": [
            x.lower().lstrip(".") for x in meta.selected_extensions
        ],
        "expected_file_count": meta.expected_file_count,
        "expected_bytes": meta.expected_bytes,
        "received_at": now_iso(),
        "status": "uploading",
        "server_version": "1.5",
    }

    (directory / "event.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )

    return {
        "ok": True,
        "saved_to": str(directory / "event.json"),
        "expected_file_count": meta.expected_file_count,
    }


@app.post("/upload-file")
@app.post("/upload-raw")
async def upload_file(
    request: Request,
    event_name: str = Query("TEST"),
    relative_path: str = Query(""),
    filename: str = Query("upload.bin"),
    job_id: str = Query(""),
):
    root = event_root(event_name)

    # Idempotency:
    # nếu client mất response và retry cùng job_id,
    # server không tạo thêm bản sao.
    if job_id:
        existing = lookup_received_job(root, job_id)

        if existing is not None:
            return JSONResponse({
                "ok": True,
                "duplicate_retry": True,
                "job_id": job_id,
                **existing,
            })

    filename = Path(safe_piece(filename)).name or "upload.bin"
    relative = safe_piece(relative_path or filename)

    parts = [
        p for p in relative.split("/")
        if p not in ("", ".", "..")
    ]
    subdirs = parts[:-1]

    incomplete_dir = root / "_INCOMPLETE"
    incomplete_dir.mkdir(parents=True, exist_ok=True)

    temp_token = job_id or uuid.uuid4().hex
    temp_path = incomplete_dir / f"{temp_token}_{filename}.part"

    # Nếu cùng job đang retry sau crash, dọn temp cũ best effort.
    await safe_delete(temp_path)

    total = 0
    started = time.perf_counter()

    try:
        with temp_path.open("xb") as f:
            async for chunk in request.stream():
                if not chunk:
                    continue

                f.write(chunk)
                total += len(chunk)

        dest_dir = destination_base(root, filename)

        for part in subdirs:
            dest_dir = dest_dir / safe_piece(part)[:120]

        dest_dir.mkdir(parents=True, exist_ok=True)

        async with finalize_lock:
            # Re-check job id after receiving body in case a racing retry won.
            if job_id:
                jobs = load_jobs(root)

                if job_id in jobs:
                    await safe_delete(temp_path)
                    info = jobs[job_id]

                    return JSONResponse({
                        "ok": True,
                        "duplicate_retry": True,
                        "job_id": job_id,
                        **info,
                    })

            final_path = unique_path(dest_dir / filename)
            temp_path.replace(final_path)

            elapsed = max(time.perf_counter() - started, 0.001)

            info = {
                "bytes": total,
                "seconds": round(elapsed, 3),
                "saved_to": str(final_path),
                "relative_path": relative,
                "filename": filename,
                "received_at": now_iso(),
            }

            if job_id:
                jobs = load_jobs(root)
                jobs[job_id] = info
                save_jobs(root, jobs)

                marker = write_upload_complete_from_jobs(root, jobs)
            else:
                marker = None

        return JSONResponse({
            "ok": True,
            "job_id": job_id or None,
            **info,
            "event_complete": marker is not None,
        })

    except ClientDisconnect:
        await safe_delete(temp_path)

        return JSONResponse(
            {
                "ok": False,
                "error": "client_disconnected",
                "job_id": job_id or None,
            },
            status_code=499,
        )

    except Exception:
        await safe_delete(temp_path)
        raise


# Backward-compatible explicit completion endpoint.
@app.post("/complete-event")
def complete_event(info: EventComplete):
    root = event_root(info.event_name)
    directory = event_dir(root)

    completion = {
        "event_name": info.event_name,
        "selected_extensions": [
            x.lower().lstrip(".")
            for x in info.selected_extensions
        ],
        "file_count": info.file_count,
        "total_bytes": info.total_bytes,
        "completed_at": now_iso(),
        "status": "complete",
        "auto_completed_by_server": False,
    }

    marker = directory / "UPLOAD_COMPLETE.json"

    marker.write_text(
        json.dumps(completion, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )

    meta_path = directory / "event.json"

    if meta_path.exists():
        try:
            current = json.loads(
                meta_path.read_text(encoding="utf-8")
            )

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

    return {
        "ok": True,
        "marker": str(marker),
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000
    )
