"""Parse Insta360 media paths from UCD2 / protobuf payloads."""

from __future__ import annotations

import re

# 本体: /storage_internal/DCIM/...  SD: /DCIM/...
STORAGE_PATH_RE = re.compile(
    rb"/storage_[a-z0-9_]+/DCIM/Camera\d+/[A-Z0-9_]+\.[A-Za-z0-9]+"
)
SD_PATH_RE = re.compile(rb"/DCIM/Camera\d+/[A-Z0-9_]+\.[A-Za-z0-9]+")
FILENAME_RE = re.compile(r"^[A-Z0-9_]+\.[A-Za-z0-9]+$")

STORAGE_LABELS = {
    "sd": "SD",
    "internal": "本体",
}


def storage_from_path(path: str) -> str:
    if path.startswith("/storage_internal/"):
        return "internal"
    if path.startswith("/storage_"):
        segment = path.split("/", 3)[2]
        return segment.removeprefix("storage_") or segment
    return "sd"


def local_filename(name: str, storage: str) -> str:
    if storage in ("", "sd"):
        return name
    stem, dot, ext = name.rpartition(".")
    suffix = "internal" if storage == "internal" else storage
    return f"{stem}_{suffix}.{ext}" if dot else f"{name}_{suffix}"


def display_label(storage: str) -> str:
    return STORAGE_LABELS.get(storage, storage)


def companion_raw_path(source_path: str) -> str | None:
    """Return companion DNG path for a JPG, or None."""
    if not source_path.lower().endswith(".jpg"):
        return None
    return f"{source_path[:-4]}.dng"


def parse_media_paths(data: bytes) -> list[str]:
    """Return unique media paths; prefer full /storage_*/DCIM paths over embedded /DCIM matches."""
    seen: set[str] = set()
    paths: list[str] = []
    occupied: list[tuple[int, int]] = []

    def add(span: tuple[int, int], path: str) -> None:
        if path in seen:
            return
        if not FILENAME_RE.fullmatch(path.rsplit("/", 1)[-1]):
            return
        seen.add(path)
        paths.append(path)
        occupied.append(span)

    for match in STORAGE_PATH_RE.finditer(data):
        add(match.span(), match.group(0).decode("ascii"))

    for match in SD_PATH_RE.finditer(data):
        start, end = match.span()
        if any(not (end <= left or start >= right) for left, right in occupied):
            continue
        add((start, end), match.group(0).decode("ascii"))

    return dedupe_storage_paths(paths)


def dedupe_storage_paths(paths: list[str]) -> list[str]:
    """Drop bare /DCIM paths when the same file is also listed under /storage_internal.

    The camera protobuf often embeds both forms for internal-storage files. Only the
    /storage_internal/... path is valid for HTTP; the bare /DCIM/... copy is not on SD.
    """
    internal_suffixes = {
        path[len("/storage_internal") :]
        for path in paths
        if path.startswith("/storage_internal/")
    }
    if not internal_suffixes:
        return paths

    # Bare /DCIM paths mirror internal-storage files for JPG/video only.
    # SD-card DNG paths also use /DCIM/... and must not be dropped when a
    # /storage_internal/... entry shares the same suffix.
    dedupe_extensions = frozenset({"jpg", "jpeg", "mp4", "lrv", "insv"})
    deduped: list[str] = []
    for path in paths:
        if path.startswith("/DCIM/") and path in internal_suffixes:
            ext = path.rsplit(".", 1)[-1].lower()
            if ext in dedupe_extensions:
                continue
        deduped.append(path)
    return deduped


def build_download_url(host: str, http_port: int, source_path: str) -> str:
    return f"http://{host}:{http_port}{source_path}"
