#!/usr/bin/env python3
"""Analyze Insta360.pcap captures (UCD2 / legacy protocol)."""

from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

try:
    import dpkt
except ImportError:
    print("dpkt が必要です: pip3 install dpkt", file=sys.stderr)
    raise SystemExit(1)

UCD2 = b"UCD2"
PATH_RE = re.compile(
    rb"(?:/storage_[a-z0-9_]+)?/DCIM/Camera\d+/[A-Z0-9_]+\.[A-Za-z0-9]+"
)


def parse_ip(buf: bytes):
    for skip in (0, 2, 4):
        try:
            return dpkt.ip.IP(buf[skip:])
        except Exception:
            pass
    return None


def ip_str(raw: bytes) -> str:
    return ".".join(str(b) for b in raw)


def iter_ucd2_packets(stream: bytes):
    offset = 0
    if stream.startswith(b"\x11\x00\x00\x00") and stream[4:7] == bytes([6, 0, 0]):
        yield {"kind": "sync", "raw": stream[: int.from_bytes(stream[:4], "little")]}
        offset = int.from_bytes(stream[:4], "little")
    while offset + 16 <= len(stream):
        if stream[offset : offset + 4] != UCD2:
            next_offset = stream.find(UCD2, offset + 1)
            if next_offset < 0:
                break
            offset = next_offset
            continue
        plen = struct.unpack_from("<I", stream, offset + 8)[0]
        end = offset + 12 + plen + 4
        if end > len(stream):
            break
        packet = stream[offset:end]
        if packet[5:7] == bytes([0x0C, 0x05]):
            yield {"kind": "keepalive", "seq": packet[7], "raw": packet}
        else:
            yield {
                "kind": "data",
                "seq": packet[7],
                "status": struct.unpack_from("<H", packet, 12)[0],
                "cmd": struct.unpack_from("<H", packet, 14)[0],
                "raw": packet,
            }
        offset = end


def analyze(path: Path, host_a: str, host_b: str) -> None:
    tcp_streams: dict[tuple[str, int, str, int], bytearray] = {}
    http_paths: list[str] = []

    with path.open("rb") as handle:
        for _, buf in dpkt.pcap.Reader(handle):
            ip = parse_ip(buf)
            if ip is None or not isinstance(ip.data, dpkt.tcp.TCP):
                continue
            src, dst = ip_str(ip.src), ip_str(ip.dst)
            if {src, dst} != {host_a, host_b}:
                continue
            tcp = ip.data
            if not tcp.data:
                continue
            key = (src, tcp.sport, dst, tcp.dport)
            tcp_streams.setdefault(key, bytearray()).extend(tcp.data)
            if tcp.dport == 80 and src == host_b:
                first = tcp.data.split(b"\r\n", 1)[0].decode("utf-8", errors="replace")
                if first.startswith("GET "):
                    http_paths.append(first)

    print(f"=== {path} ===")
    print(f"hosts: {host_a} <-> {host_b}")
    print()

    for key, stream in sorted(tcp_streams.items()):
        src, sport, dst, dport = key
        print(f"TCP {src}:{sport} -> {dst}:{dport} ({len(stream)} bytes)")
        if dport == 6666 or sport == 6666:
            if stream[:4] == b"\x11\x00\x00\x00":
                print("  protocol: UCD2 (Luna Ultra 系)")
            elif b"syNceNdinS" in stream[:32]:
                print("  protocol: legacy (syNceNdinS)")
            else:
                print("  protocol: unknown")
            packets = list(iter_ucd2_packets(bytes(stream)))
            data_cmds = [p for p in packets if p["kind"] == "data"]
            if data_cmds:
                cmds = ", ".join(f"0x{p['cmd']:04x}" for p in data_cmds[:20])
                print(f"  UCD2 commands (first 20): {cmds}")
            paths = sorted(set(m.group(0).decode() for m in PATH_RE.finditer(stream)))
            if paths:
                print(f"  media paths in stream: {len(paths)}")
                for item in paths[:5]:
                    print(f"    {item}")
                if len(paths) > 5:
                    print("    ...")
        print()

    if http_paths:
        print("HTTP GET (first 10):")
        for line in http_paths[:10]:
            print(f"  {line}")
        print(f"  total GET requests: {len(http_paths)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze Insta360 Wi-Fi pcap captures")
    parser.add_argument("pcap", type=Path)
    parser.add_argument("--camera", default="192.168.42.1")
    parser.add_argument("--client", default="192.168.42.196")
    args = parser.parse_args()
    analyze(args.pcap, args.camera, args.client)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
