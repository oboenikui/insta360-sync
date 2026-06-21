"""Insta360 Luna Ultra UCD2 protocol (TCP/6666).

Reverse-engineered from iPhone app traffic capture. This is NOT compatible with
the legacy ONE RS protocol (syNceNdinS + 0x04 packets) documented in
insta360-wifi-api.
"""

from __future__ import annotations

from insta360_paths import build_download_url, parse_media_paths, storage_from_path
import socket
import struct
import threading
import time
from dataclasses import dataclass

from ucd2_luna_templates import SYNC_FRAME
from ucd2_packets import build_handshake_segments, expand_ucd2_packets

DEFAULT_HOST = "192.168.42.1"
DEFAULT_TCP_PORT = 6666
DEFAULT_HTTP_PORT = 80

UCD2_MAGIC = b"UCD2"


class UCD2Error(Exception):
    pass


class ClientLog:
    def __init__(self, verbose: int = 0) -> None:
        self.verbose = verbose

    def info(self, message: str) -> None:
        print(message)

    def debug(self, message: str) -> None:
        if self.verbose >= 1:
            print(f"[debug] {message}")

    def trace(self, message: str) -> None:
        if self.verbose >= 2:
            print(f"[trace] {message}")


@dataclass
class UCD2File:
    source_path: str
    download_url: str
    name: str = ""
    storage: str = "sd"

    def __post_init__(self) -> None:
        if not self.name:
            self.name = self.source_path.rsplit("/", 1)[-1]
        if self.storage == "sd":
            self.storage = storage_from_path(self.source_path)


def parse_paths_from_payload(data: bytes) -> list[str]:
    return parse_media_paths(data)

def iter_ucd2_packets(stream: bytes):
    offset = 0
    while offset + 16 <= len(stream):
        if stream[offset : offset + 4] != UCD2_MAGIC:
            next_offset = stream.find(UCD2_MAGIC, offset + 1)
            if next_offset < 0:
                break
            offset = next_offset
            continue
        payload_len = struct.unpack_from("<I", stream, offset + 8)[0]
        end = offset + 12 + payload_len + 4
        if end > len(stream) or end <= offset:
            break
        packet = stream[offset:end]
        msg_type = stream[offset + 5 : offset + 7]
        if msg_type == bytes([0x0C, 0x05]):
            yield {"kind": "keepalive", "seq": packet[7], "raw": packet}
        elif msg_type == bytes([0x0C, 0x04]):
            status = struct.unpack_from("<H", packet, 12)[0]
            cmd = struct.unpack_from("<H", packet, 14)[0]
            body = packet[19 : 12 + payload_len]
            yield {
                "kind": "data",
                "seq": packet[7],
                "status": status,
                "cmd": cmd,
                "body": body,
                "raw": packet,
            }
        offset = end


class UCD2Client:
    def __init__(
        self,
        host: str = DEFAULT_HOST,
        port: int = DEFAULT_TCP_PORT,
        log: object | None = None,
    ) -> None:
        self.host = host
        self.port = port
        self.log = log
        self.sock: socket.socket | None = None
        self.buffer = bytearray()
        self.lock = threading.Lock()
        self._recv_thread: threading.Thread | None = None
        self._closed = False
        self.received = bytearray()

    def _info(self, message: str) -> None:
        if self.log is not None and hasattr(self.log, "info"):
            self.log.info(message)

    def _debug(self, message: str) -> None:
        if self.log is not None and hasattr(self.log, "debug"):
            self.log.debug(message)

    def _trace(self, message: str) -> None:
        if self.log is not None and hasattr(self.log, "trace"):
            self.log.trace(message)

    def open(self) -> None:
        self.close()
        self._closed = False
        self._debug(f"UCD2 connect -> {self.host}:{self.port}")
        try:
            self.sock = socket.create_connection((self.host, self.port), timeout=10)
        except OSError as exc:
            raise UCD2Error(f"TCP connect failed: {exc}") from exc
        self.sock.settimeout(0.5)
        self._recv_thread = threading.Thread(target=self._recv_loop, daemon=True)
        self._recv_thread.start()

    def close(self) -> None:
        self._closed = True
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def list_files(
        self,
        http_port: int = DEFAULT_HTTP_PORT,
        wait_seconds: float = 15.0,
        stable_seconds: float = 1.0,
    ) -> list[UCD2File]:
        if self.sock is None:
            raise UCD2Error("not connected")

        self._debug(f"send sync frame ({len(SYNC_FRAME)} bytes)")
        self._send(SYNC_FRAME)
        time.sleep(0.05)

        segments = expand_ucd2_packets(build_handshake_segments(skip_time_sync=True))
        self._debug(f"send handshake ({len(segments)} packets, time-sync omitted)")
        for index, segment in enumerate(segments):
            self._debug(
                f"send handshake packet {index + 1}/{len(segments)} ({len(segment)} bytes)"
            )
            self._send(segment)
            time.sleep(0.02)

        best_paths: list[str] = []
        last_count = 0
        stable_since: float | None = None
        deadline = time.time() + wait_seconds
        while time.time() < deadline:
            with self.lock:
                payload = bytes(self.received)
            current = parse_paths_from_payload(payload)
            if len(current) > last_count:
                best_paths = current
                last_count = len(current)
                stable_since = time.time()
                dng_count = sum(1 for path in current if path.lower().endswith(".dng"))
                self._debug(
                    f"file list growing: {len(current)} paths ({dng_count} dng)"
                )
            elif best_paths and stable_since is not None:
                if time.time() - stable_since >= stable_seconds:
                    break
            time.sleep(0.05)

        if best_paths:
            dng_count = sum(1 for path in best_paths if path.lower().endswith(".dng"))
            self._info(f"UCD2 file list received ({len(best_paths)} paths, {dng_count} dng)")
            return [
                UCD2File(
                    source_path=path,
                    download_url=build_download_url(self.host, http_port, path),
                    name=path.rsplit("/", 1)[-1],
                    storage=storage_from_path(path),
                )
                for path in best_paths
            ]

        with self.lock:
            payload = bytes(self.received)
        packets = list(iter_ucd2_packets(payload))
        cmds = [f"0x{p['cmd']:04x}" for p in packets if p["kind"] == "data"]
        raise UCD2Error(
            "timed out waiting for file list; "
            f"received {len(payload)} bytes, parsed packets={len(packets)}, cmds={cmds[:20]}"
        )

    def _send(self, data: bytes) -> None:
        if self.sock is None:
            raise UCD2Error("not connected")
        self.sock.sendall(data)

    def _handle_incoming(self, chunk: bytes) -> None:
        offset = 0
        while offset + 16 <= len(chunk):
            if chunk[offset : offset + 4] != UCD2_MAGIC:
                break
            payload_len = struct.unpack_from("<I", chunk, offset + 8)[0]
            end = offset + 12 + payload_len + 4
            if end > len(chunk):
                break
            packet = chunk[offset:end]
            if packet[5:7] == bytes([0x0C, 0x05]) and not self._closed:
                self._reply_keepalive(packet[7])
            offset = end

    def _reply_keepalive(self, camera_seq: int) -> None:
        # iPhone app echoes keepalives while HTTP downloads run; checksum is still unknown.
        # Reuse the outbound template from capture (seq byte + trailing checksum).
        reply_seq = (camera_seq + 4) & 0xFF
        templates = {
            0x05: bytes.fromhex("55434432010c05050000000065ed78ed"),
            0x1D: bytes.fromhex("55434432010c051d00000000ea6f132a"),
            0x1E: bytes.fromhex("55434432010c051e000000000d3c6612"),
            0x21: bytes.fromhex("55434432010c052100000000df38d041"),
            0x22: bytes.fromhex("55434432010c052200000000386ba579"),
        }
        packet = templates.get(reply_seq)
        if packet is None:
            packet = bytes([0x55, 0x43, 0x44, 0x32, 0x01, 0x0C, 0x05, reply_seq, 0, 0, 0, 0, 0, 0, 0, 0])
        try:
            self._send(packet)
            self._trace(f"keepalive reply seq=0x{reply_seq:02x}")
        except UCD2Error:
            pass

    def _recv_loop(self) -> None:
        assert self.sock is not None
        try:
            while not self._closed:
                try:
                    chunk = self.sock.recv(65536)
                except socket.timeout:
                    continue
                except OSError as exc:
                    if not self._closed:
                        self._debug(f"recv error: {exc}")
                    break
                if not chunk:
                    break
                self._handle_incoming(chunk)
                with self.lock:
                    self.received.extend(chunk)
                self._trace(f"recv {len(chunk)} bytes")
        finally:
            self._debug("recv loop ended")
