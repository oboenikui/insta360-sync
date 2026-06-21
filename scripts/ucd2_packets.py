"""Build UCD2 packets for Luna Ultra (avoid replaying captured wall-clock timestamps)."""

from __future__ import annotations

import struct
from typing import Iterable

from ucd2_luna_templates import FILE_LIST_CONTINUATION_SEGMENTS, FILE_LIST_REQUEST_SEGMENTS as _CAPTURED_SEGMENTS

# Handshake segment that carries phone time + timezone (protobuf field 12 = unix seconds).
# Replaying the capture shifts the camera clock to the pcap date (2026-06-21 ~18:00 JST).
TIME_SYNC_CMD = 0x0202


def ucd2_cmd(packet: bytes) -> int:
    if len(packet) < 16 or packet[:4] != b"UCD2":
        raise ValueError("not a UCD2 packet")
    payload_len = struct.unpack_from("<I", packet, 8)[0]
    if len(packet) < 12 + payload_len + 4:
        raise ValueError("truncated UCD2 packet")
    return struct.unpack_from("<H", packet, 14)[0]


def build_handshake_segments(*, skip_time_sync: bool = True) -> list[bytes]:
    """Return UCD2 handshake packets for file listing.

  By default the captured time-sync segment (cmd 0x0202, Asia/Tokyo + unix time) is
  omitted so the camera clock is not overwritten with the pcap timestamp.
  """
    segments: list[bytes] = []
    for packet in _CAPTURED_SEGMENTS:
        if skip_time_sync and ucd2_cmd(packet) == TIME_SYNC_CMD:
            continue
        segments.append(packet)
    segments.extend(FILE_LIST_CONTINUATION_SEGMENTS)
    return segments


def handshake_blob(segments: Iterable[bytes] | None = None) -> bytes:
    return b"".join(expand_ucd2_packets(segments or build_handshake_segments()))


def expand_ucd2_packets(segments: Iterable[bytes]) -> list[bytes]:
    """Split captured blobs that contain multiple concatenated UCD2 packets."""
    packets: list[bytes] = []
    for segment in segments:
        offset = 0
        data = segment
        while offset + 16 <= len(data):
            if data[offset : offset + 4] != b"UCD2":
                break
            payload_len = struct.unpack_from("<I", data, offset + 8)[0]
            end = offset + 12 + payload_len + 4
            if end > len(data):
                packets.append(data[offset:])
                break
            packets.append(data[offset:end])
            offset = end
    return packets
