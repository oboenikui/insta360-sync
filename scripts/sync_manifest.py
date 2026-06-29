"""Persist synced camera files for skip-on-next-sync."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import Protocol


MANIFEST_VERSION = 1
MANIFEST_DIR = ".insta360-sync"
MANIFEST_FILENAME = "manifest.json"


@dataclass
class SyncedFileRecord:
    name: str
    storage: str
    size: int | None
    capture_time: int | None
    synced_at: str

    def matches(self, *, name: str, storage: str, size: int | None, capture_time: int | None) -> bool:
        if self.name != name or self.storage != storage:
            return False
        if self.size is not None and size is not None and self.size != size:
            return False
        if self.capture_time is not None and capture_time is not None and self.capture_time != capture_time:
            return False
        return True


class SyncableFile(Protocol):
    source_path: str
    name: str
    storage: str
    size: int | None
    capture_time: int | None


def manifest_path(destination_dir: str) -> str:
    return os.path.join(os.path.abspath(destination_dir), MANIFEST_DIR, MANIFEST_FILENAME)


def load_manifest(destination_dir: str) -> dict[str, SyncedFileRecord]:
    path = manifest_path(destination_dir)
    try:
        with open(path, encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    if raw.get("version") != MANIFEST_VERSION:
        return {}
    files = raw.get("files") or {}
    out: dict[str, SyncedFileRecord] = {}
    for source_path, item in files.items():
        if not isinstance(item, dict):
            continue
        out[source_path] = SyncedFileRecord(
            name=str(item.get("name") or ""),
            storage=str(item.get("storage") or "sd"),
            size=item.get("size"),
            capture_time=item.get("capture_time"),
            synced_at=str(item.get("synced_at") or ""),
        )
    return out


def save_manifest(destination_dir: str, records: dict[str, SyncedFileRecord]) -> None:
    path = manifest_path(destination_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    payload = {
        "version": MANIFEST_VERSION,
        "files": {source_path: asdict(record) for source_path, record in records.items()},
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def is_synced(file: SyncableFile, records: dict[str, SyncedFileRecord]) -> bool:
    record = records.get(file.source_path)
    if record is None:
        return False
    return record.matches(
        name=file.name,
        storage=file.storage,
        size=file.size,
        capture_time=file.capture_time,
    )


def mark_synced(
    records: dict[str, SyncedFileRecord],
    file: SyncableFile,
    *,
    size: int | None = None,
) -> None:
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    records[file.source_path] = SyncedFileRecord(
        name=file.name,
        storage=file.storage,
        size=size if size is not None else file.size,
        capture_time=file.capture_time,
        synced_at=now,
    )


def apply_sync_state(files: list[SyncableFile], destination_dir: str) -> dict[str, SyncedFileRecord]:
    records = load_manifest(destination_dir)
    for file in files:
        if hasattr(file, "synced"):
            file.synced = is_synced(file, records)  # type: ignore[attr-defined]
    return records
