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


def build_list_file_phases(*, skip_time_sync: bool = True) -> list[tuple[list[bytes], float]]:
    """Return handshake packets in phases with post-phase delays (from iPhone pcap).

    DNG paths arrive in a second burst after cmd 0x1502; blasting all continuation
    packets at once often leaves clients with JPG-only lists.
    """
    initial: list[bytes] = []
    for packet in _CAPTURED_SEGMENTS:
        if skip_time_sync and ucd2_cmd(packet) == TIME_SYNC_CMD:
            continue
        initial.append(packet)

    continuation = list(FILE_LIST_CONTINUATION_SEGMENTS)
    groups = [
        initial,
        continuation[0:5],   # 0x1102 .. 0x1502
        continuation[5:8],   # 0x1602 .. 0x1802
        continuation[8:11],  # 0x1902 .. 0x1b02
        continuation[11:13],  # 0x1c02 .. 0x1d02
        continuation[13:],    # 0x1e02 .. 0x2a02
    ]
    delays = [0.70, 0.15, 0.60, 3.00, 4.50, 0.0]
    phases: list[tuple[list[bytes], float]] = []
    for index, (group, delay) in enumerate(zip(groups, delays)):
        packets = expand_ucd2_packets(group)
        if packets:
            phases.append((packets, delay if index < len(delays) else 0.0))
    return phases


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
