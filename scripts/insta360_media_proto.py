"""Parse Insta360 Luna Ultra UCD2 file-list protobuf entries."""

from __future__ import annotations

import re
from dataclasses import dataclass

from insta360_paths import dedupe_storage_paths, parse_media_paths

CAPTURE_TIME_RE = re.compile(
    r"^(?:VID|IMG|LRV)_(\d{4})(\d{2})(\d{2})_(\d{6})",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class MediaFileEntry:
    source_path: str
    size: int | None = None
    capture_time: int | None = None


def capture_time_from_filename(name: str) -> int | None:
    match = CAPTURE_TIME_RE.match(name)
    if not match:
        return None
    y, mo, d, t = match.groups()
    return int(f"{y}{mo}{d}{t}")


def _read_varint(data: bytes, offset: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while offset < len(data):
        byte = data[offset]
        offset += 1
        result |= (byte & 0x7F) << shift
        if not (byte & 0x80):
            return result, offset
        shift += 7
        if shift > 63:
            raise ValueError("invalid varint")
    raise ValueError("unexpected EOF while reading varint")


def _skip_field(data: bytes, wire_type: int, offset: int) -> int:
    if wire_type == 0:
        _, offset = _read_varint(data, offset)
        return offset
    if wire_type == 2:
        length, offset = _read_varint(data, offset)
        return offset + length
    if wire_type == 1:
        return offset + 8
    if wire_type == 5:
        return offset + 4
    raise ValueError(f"unsupported wire type {wire_type}")


def _parse_nested_meta(meta: bytes) -> tuple[int | None, int | None]:
    capture_time: int | None = None
    size: int | None = None
    offset = 0
    while offset < len(meta):
        key, offset = _read_varint(meta, offset)
        field = key >> 3
        wire = key & 7
        if wire == 0:
            value, offset = _read_varint(meta, offset)
            if field == 7:
                capture_time = value
            elif field == 9:
                size = value
        else:
            offset = _skip_field(meta, wire, offset)
    return capture_time, size


def _parse_file_entry(entry: bytes) -> tuple[int | None, int | None]:
    capture_time: int | None = None
    size: int | None = None
    offset = 0
    while offset < len(entry):
        key, offset = _read_varint(entry, offset)
        field = key >> 3
        wire = key & 7
        if field == 1 and wire == 2:
            length, offset = _read_varint(entry, offset)
            offset += length
        elif field == 2 and wire == 2:
            length, offset = _read_varint(entry, offset)
            meta = entry[offset : offset + length]
            ct, sz = _parse_nested_meta(meta)
            if ct is not None:
                capture_time = ct
            if sz is not None:
                size = sz
            break
        else:
            try:
                offset = _skip_field(entry, wire, offset)
            except ValueError:
                break
    return capture_time, size


def _meta_at_path(data: bytes, path_offset: int, path_len: int) -> tuple[int | None, int | None]:
    for tag_pos in range(max(0, path_offset - 12), path_offset):
        if data[tag_pos] != 0x0A:
            continue
        try:
            str_len, str_start = _read_varint(data, tag_pos + 1)
        except ValueError:
            continue
        if str_start == path_offset and str_len == path_len:
            try:
                return _parse_file_entry(data[tag_pos:])
            except ValueError:
                return None, None
    return None, None


def parse_media_file_entries(data: bytes) -> list[MediaFileEntry]:
    """Return media paths with UCD2 protobuf metadata (field 7=capture time, field 9=size)."""
    paths = dedupe_storage_paths(parse_media_paths(data))
    entries: list[MediaFileEntry] = []
    for path in paths:
        path_bytes = path.encode("ascii")
        capture_time: int | None = None
        size: int | None = None
        search = 0
        while search >= 0:
            idx = data.find(path_bytes, search)
            if idx < 0:
                break
            ct, sz = _meta_at_path(data, idx, len(path_bytes))
            if ct is not None:
                capture_time = ct
            if sz is not None:
                size = sz
            if capture_time is not None or size is not None:
                break
            search = idx + 1
        name = path.rsplit("/", 1)[-1]
        if capture_time is None:
            capture_time = capture_time_from_filename(name)
        entries.append(
            MediaFileEntry(
                source_path=path,
                size=size,
                capture_time=capture_time,
            )
        )
    return entries
