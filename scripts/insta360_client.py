"""Insta360 camera client (TCP + OSC fallback) for manual verification."""

from __future__ import annotations

import json
import os
import socket
import struct
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, TextIO
from urllib.parse import urljoin

DEFAULT_HOST = "192.168.42.1"
DEFAULT_TCP_PORT = 6666
DEFAULT_HTTP_PORT = 80

PKT_SYNC = bytes([0x06, 0x00, 0x00]) + b"syNceNdinS"
PKT_KEEPALIVE = bytes([0x05, 0x00, 0x00])

PHONE_COMMAND_GET_FILE_LIST = 13
RESPONSE_CODE_OK = 200
RESPONSE_CODE_ERROR = 500


class Insta360Error(Exception):
    def __init__(self, message: str, attempts: list[str] | None = None) -> None:
        super().__init__(message)
        self.attempts = attempts or []


@dataclass
class CameraFile:
    source_path: str
    download_url: str
    size: int | None = None
    name: str = ""
    storage: str = "sd"
    capture_time: int | None = None
    synced: bool = False

    def __post_init__(self) -> None:
        if not self.name:
            self.name = self.source_path.rsplit("/", 1)[-1]
        if self.storage == "sd" and self.source_path.startswith("/storage_"):
            from insta360_paths import storage_from_path

            self.storage = storage_from_path(self.source_path)
        if self.capture_time is None:
            from insta360_media_proto import capture_time_from_filename

            self.capture_time = capture_time_from_filename(self.name)

    @property
    def local_name(self) -> str:
        from insta360_paths import local_filename

        return local_filename(self.name, self.storage)

    @property
    def display_name(self) -> str:
        from insta360_paths import display_label

        label = display_label(self.storage)
        prefix = "[済] " if self.synced else ""
        return f"{prefix}[{label}] {self.name}"


@dataclass
class ClientLog:
    verbose: int = 0
    stream: TextIO = field(default_factory=lambda: sys.stderr)

    def info(self, message: str) -> None:
        print(message, file=self.stream)

    def debug(self, message: str) -> None:
        if self.verbose >= 1:
            print(f"[debug] {message}", file=self.stream)

    def trace(self, message: str) -> None:
        if self.verbose >= 2:
            print(f"[trace] {message}", file=self.stream)


def hexdump(data: bytes, limit: int = 96) -> str:
    clipped = data[:limit]
    text = clipped.hex(" ")
    if len(data) > limit:
        text += f" ... (+{len(data) - limit} bytes)"
    return text


def _encode_varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            byte |= 0x80
        out.append(byte)
        if not value:
            break
    return bytes(out)


def _decode_varint(data: bytes, offset: int) -> tuple[int, int]:
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
            raise Insta360Error("invalid varint")
    raise Insta360Error("unexpected EOF while reading varint")


def _skip_field(data: bytes, wire_type: int, offset: int) -> int:
    if wire_type == 0:
        _, offset = _decode_varint(data, offset)
        return offset
    if wire_type == 1:
        return offset + 8
    if wire_type == 2:
        length, offset = _decode_varint(data, offset)
        return offset + length
    if wire_type == 5:
        return offset + 4
    raise Insta360Error(f"unknown wire type: {wire_type}")


def encode_get_file_list(start: int = 0, limit: int = 500, media_type: int = 2) -> bytes:
    body = bytearray()
    body.extend(_encode_varint((1 << 3) | 0))
    body.extend(_encode_varint(media_type))
    if start > 0:
        body.extend(_encode_varint((2 << 3) | 0))
        body.extend(_encode_varint(start))
    body.extend(_encode_varint((3 << 3) | 0))
    body.extend(_encode_varint(limit))
    return bytes(body)


def decode_get_file_list_response(data: bytes) -> tuple[list[str], int]:
    uris: list[str] = []
    total_count = 0
    offset = 0
    while offset < len(data):
        key, offset = _decode_varint(data, offset)
        field_number = key >> 3
        wire_type = key & 0x7
        if field_number == 1 and wire_type == 2:
            length, offset = _decode_varint(data, offset)
            uris.append(data[offset : offset + length].decode("utf-8"))
            offset += length
        elif field_number == 2 and wire_type == 0:
            total_count, offset = _decode_varint(data, offset)
        else:
            offset = _skip_field(data, wire_type, offset)
    return uris, total_count


def make_command_packet(message_code: int, sequence: int, body: bytes) -> bytes:
    header = bytearray([0x04, 0x00, 0x00])
    header.extend(struct.pack("<H", message_code))
    header.append(0x02)
    header.extend(sequence.to_bytes(4, "little")[:3])
    header.extend([0x80, 0x00, 0x00])
    payload = bytes(header) + body
    return struct.pack("<I", len(payload) + 4) + payload


def frame_raw(payload: bytes) -> bytes:
    return struct.pack("<I", len(payload) + 4) + payload


def parse_packet_sequence(packet: bytes) -> int:
    seq_value = int.from_bytes(packet[6:9] + b"\x00", "little")
    if seq_value >= 0x800000:
        seq_value -= 0x1000000
    return seq_value


class TCPClient:
    def __init__(
        self,
        host: str = DEFAULT_HOST,
        port: int = DEFAULT_TCP_PORT,
        log: ClientLog | None = None,
    ) -> None:
        self.host = host
        self.port = port
        self.log = log or ClientLog()
        self.sock: socket.socket | None = None
        self.sequence = 0
        self.buffer = bytearray()
        self.pending: dict[int, tuple[threading.Event, list[Any]]] = {}
        self.lock = threading.Lock()
        self._recv_thread: threading.Thread | None = None
        self._closed = False
        self.received_packets = 0

    def open(self) -> None:
        self.close()
        self._closed = False
        self.log.debug(f"TCP connect -> {self.host}:{self.port}")
        try:
            self.sock = socket.create_connection((self.host, self.port), timeout=10)
        except OSError as exc:
            raise Insta360Error(f"TCP connect failed: {exc}") from exc
        local = self.sock.getsockname()
        self.log.debug(f"TCP connected local={local[0]}:{local[1]}")
        self.sock.settimeout(30)
        self.log.trace(f"send sync {hexdump(PKT_SYNC)}")
        self._send_raw(PKT_SYNC)
        self.log.trace(f"send keepalive {hexdump(PKT_KEEPALIVE)}")
        self._send_raw(PKT_KEEPALIVE)
        self._recv_thread = threading.Thread(target=self._recv_loop, daemon=True)
        self._recv_thread.start()
        self.log.debug("TCP recv thread started")

    def close(self) -> None:
        self._closed = True
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
        with self.lock:
            for _, (event, bucket) in self.pending.items():
                bucket.append(Insta360Error("connection closed"))
                event.set()
            self.pending.clear()

    def list_all_files(self, http_port: int = DEFAULT_HTTP_PORT) -> list[CameraFile]:
        files: list[CameraFile] = []
        start = 0
        limit = 500
        total_count: int | None = None
        page = 0

        while True:
            page += 1
            body = encode_get_file_list(start=start, limit=limit)
            self.log.debug(
                f"TCP GetFileList page={page} start={start} limit={limit} body={hexdump(body, 32)}"
            )
            response_body = self._send_command(PHONE_COMMAND_GET_FILE_LIST, body)
            uris, page_total = decode_get_file_list_response(response_body)
            if total_count is None:
                total_count = page_total
            self.log.debug(
                f"TCP GetFileList page={page} uris={len(uris)} total_count={total_count}"
            )
            if not uris:
                break
            for uri in uris:
                files.append(
                    CameraFile(
                        source_path=uri,
                        download_url=f"http://{self.host}:{http_port}{uri}",
                    )
                )
            start += len(uris)
            if total_count is not None and start >= total_count:
                break

        return files

    def _send_raw(self, payload: bytes) -> None:
        if self.sock is None:
            raise Insta360Error("TCP connection is not open")
        framed = frame_raw(payload)
        self.log.trace(f"send framed len={len(framed)} data={hexdump(framed, 48)}")
        self.sock.sendall(framed)

    def _send_command(self, code: int, body: bytes) -> bytes:
        with self.lock:
            seq = self.sequence
            self.sequence += 1
            event = threading.Event()
            self.pending[seq] = (event, [])
        packet = make_command_packet(code, seq, body)
        self.log.debug(f"TCP command code={code} seq={seq} packet={hexdump(packet, 48)}")
        self._send_raw(packet)
        if not event.wait(timeout=30):
            with self.lock:
                pending_seqs = sorted(self.pending)
                self.pending.pop(seq, None)
            raise Insta360Error(
                f"camera command timed out (seq={seq}, pending={pending_seqs}, "
                f"received_packets={self.received_packets})"
            )
        with self.lock:
            pending = self.pending.pop(seq, None)
        if pending is None:
            raise Insta360Error("missing camera response")
        _, bucket = pending
        if not bucket:
            raise Insta360Error("empty camera response")
        result = bucket[0]
        if isinstance(result, Exception):
            raise result
        return result

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
                        self.log.debug(f"TCP recv error: {exc}")
                    break
                if not chunk:
                    self.log.debug("TCP recv EOF")
                    break
                self.log.trace(f"TCP recv chunk len={len(chunk)} data={hexdump(chunk, 48)}")
                self.buffer.extend(chunk)
                self._process_buffer()
        finally:
            self.close()

    def _process_buffer(self) -> None:
        while len(self.buffer) >= 4:
            packet_length = struct.unpack_from("<I", self.buffer, 0)[0]
            if packet_length < 4 or len(self.buffer) < packet_length:
                break
            packet = bytes(self.buffer[4:packet_length])
            del self.buffer[:packet_length]
            self._handle_packet(packet)

    def _handle_packet(self, packet: bytes) -> None:
        self.received_packets += 1
        if packet in (PKT_SYNC, PKT_KEEPALIVE):
            self.log.trace(f"TCP ignore control packet {hexdump(packet, 24)}")
            return
        if len(packet) < 12:
            self.log.debug(f"TCP short packet len={len(packet)} data={hexdump(packet)}")
            return
        response_code = struct.unpack_from("<H", packet, 3)[0]
        seq = parse_packet_sequence(packet)
        body = packet[12:]
        self.log.trace(
            f"TCP packet code={response_code} seq={seq} body_len={len(body)} raw={hexdump(packet, 48)}"
        )

        with self.lock:
            pending = self.pending.get(seq)
            if pending is None:
                self.log.debug(
                    f"TCP unmatched response code={response_code} seq={seq} "
                    f"pending={sorted(self.pending)} raw={hexdump(packet, 48)}"
                )
                return
            event, bucket = pending

        if response_code == RESPONSE_CODE_ERROR:
            message = body.decode("utf-8", errors="replace") or "unknown"
            bucket.append(Insta360Error(f"camera error: {message}"))
            event.set()
            return

        if response_code == RESPONSE_CODE_OK:
            bucket.append(body)
            event.set()


class OSCClient:
    def __init__(
        self,
        host: str = DEFAULT_HOST,
        http_port: int = DEFAULT_HTTP_PORT,
        log: ClientLog | None = None,
    ) -> None:
        self.base_url = f"http://{host}:{http_port}/"
        self.host = host
        self.http_port = http_port
        self.log = log or ClientLog()

    def probe(self) -> tuple[bool, str]:
        url = urljoin(self.base_url, "osc/info")
        self.log.debug(f"OSC GET {url}")
        try:
            request = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(request, timeout=5) as response:
                body = response.read(512)
                status = response.getcode()
        except urllib.error.HTTPError as exc:
            body = exc.read(256) if exc.fp else b""
            return False, f"HTTP {exc.code} {exc.reason}; body={body[:200]!r}"
        except urllib.error.URLError as exc:
            return False, f"URL error: {exc.reason}"
        except TimeoutError:
            return False, "timeout"
        except OSError as exc:
            return False, f"OS error: {exc}"

        if status != 200:
            return False, f"HTTP {status}; body={body[:200]!r}"
        try:
            payload = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError as exc:
            return False, f"invalid JSON: {exc}; body={body[:200]!r}"
        model = payload.get("model") or payload.get("manufacturer") or "unknown"
        return True, f"HTTP 200 model={model!r}"

    def is_available(self) -> bool:
        ok, _ = self.probe()
        return ok

    def list_all_files(self) -> list[CameraFile]:
        files: list[CameraFile] = []
        start_position = 0
        page_size = 50
        total_entries: int | None = None
        page = 0

        while True:
            page += 1
            command = {
                "name": "camera.listFiles",
                "parameters": {
                    "fileType": "all",
                    "startPosition": start_position,
                    "entryCount": page_size,
                    "maxThumbSize": 0,
                },
            }
            self.log.debug(f"OSC camera.listFiles page={page} start={start_position}")
            result = self._execute_command(command)
            results = result.get("results")
            if not isinstance(results, dict):
                break
            if total_entries is None:
                total_entries = results.get("totalEntries")
            entries = results.get("entries")
            if not isinstance(entries, list):
                break
            self.log.debug(
                f"OSC camera.listFiles page={page} entries={len(entries)} total={total_entries}"
            )
            if not entries:
                break
            for entry in entries:
                if not isinstance(entry, dict):
                    continue
                name = entry.get("name") or "unknown"
                local_path = entry.get("_localFileUrl") or entry.get("fileUrl") or f"/DCIM/Camera01/{name}"
                if not str(local_path).startswith("/"):
                    local_path = f"/{local_path}"
                file_url = entry.get("fileUrl") or f"http://{self.host}:{self.http_port}{local_path}"
                size = entry.get("size")
                files.append(
                    CameraFile(
                        source_path=str(local_path),
                        download_url=str(file_url),
                        size=int(size) if size is not None else None,
                        name=str(name),
                    )
                )
            start_position += len(entries)
            if isinstance(total_entries, int) and start_position >= total_entries:
                break

        return files

    def _execute_command(self, command: dict[str, Any]) -> dict[str, Any]:
        url = urljoin(self.base_url, "osc/commands/execute")
        payload = json.dumps(command).encode("utf-8")
        self.log.debug(f"OSC POST {url} body={payload.decode('utf-8')[:200]}")
        request = urllib.request.Request(
            url,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                raw = response.read()
                status = response.getcode()
        except urllib.error.HTTPError as exc:
            body = exc.read(256) if exc.fp else b""
            raise Insta360Error(f"OSC execute HTTP {exc.code}: {body[:200]!r}") from exc
        except urllib.error.URLError as exc:
            raise Insta360Error(f"OSC execute failed: {exc.reason}") from exc

        if status < 200 or status >= 300:
            raise Insta360Error(f"OSC execute HTTP {status}: {raw[:200]!r}")

        try:
            data = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise Insta360Error(f"OSC execute invalid JSON: {raw[:200]!r}") from exc

        if data.get("state") == "inProgress":
            command_id = data.get("id")
            if not command_id:
                raise Insta360Error("missing OSC command id")
            return self._poll_status(str(command_id))
        return data

    def _poll_status(self, command_id: str) -> dict[str, Any]:
        url = urljoin(self.base_url, "osc/commands/status")
        for attempt in range(30):
            payload = json.dumps({"id": command_id}).encode("utf-8")
            request = urllib.request.Request(
                url,
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            self.log.trace(f"OSC poll status id={command_id} attempt={attempt + 1}")
            try:
                with urllib.request.urlopen(request, timeout=5) as response:
                    data = json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as exc:
                body = exc.read(256) if exc.fp else b""
                raise Insta360Error(f"OSC status HTTP {exc.code}: {body[:200]!r}") from exc
            except urllib.error.URLError as exc:
                raise Insta360Error(f"OSC status failed: {exc.reason}") from exc

            state = data.get("state")
            if state == "done":
                return data
            if state == "error":
                raise Insta360Error(str(data.get("error") or "OSC command failed"))
            time.sleep(1)
        raise Insta360Error("OSC command timed out")


def probe_tcp_port(host: str, port: int, log: ClientLog) -> tuple[bool, str]:
    log.debug(f"probe TCP port {host}:{port}")
    try:
        with socket.create_connection((host, port), timeout=5) as sock:
            local = sock.getsockname()
            return True, f"connect OK local={local[0]}:{local[1]}"
    except OSError as exc:
        return False, str(exc)


def probe_http_port(host: str, port: int, log: ClientLog) -> tuple[bool, str]:
    url = f"http://{host}:{port}/"
    log.debug(f"probe HTTP GET {url}")
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            body = response.read(128)
            return True, f"HTTP {response.getcode()} body={body[:80]!r}"
    except urllib.error.HTTPError as exc:
        return True, f"HTTP {exc.code} {exc.reason}"
    except urllib.error.URLError as exc:
        return False, str(exc.reason)
    except OSError as exc:
        return False, str(exc)


def run_probe(
    host: str = DEFAULT_HOST,
    tcp_port: int = DEFAULT_TCP_PORT,
    http_port: int = DEFAULT_HTTP_PORT,
    log: ClientLog | None = None,
) -> list[str]:
    log = log or ClientLog(verbose=log.verbose if log else 0, stream=log.stream if log else sys.stderr)
    lines: list[str] = []

    tcp_ok, tcp_detail = probe_tcp_port(host, tcp_port, log)
    lines.append(f"TCP port {host}:{tcp_port}: {'OK' if tcp_ok else 'NG'} ({tcp_detail})")

    http_ok, http_detail = probe_http_port(host, http_port, log)
    lines.append(f"HTTP port {host}:{http_port}: {'OK' if http_ok else 'NG'} ({http_detail})")

    osc = OSCClient(host=host, http_port=http_port, log=log)
    osc_ok, osc_detail = osc.probe()
    lines.append(f"OSC /osc/info: {'OK' if osc_ok else 'NG'} ({osc_detail})")

    try:
        from insta360_ucd2 import UCD2Client, UCD2Error

        ucd2_log = ClientLog(verbose=log.verbose, stream=log.stream)
        ucd2 = UCD2Client(host=host, port=tcp_port, log=ucd2_log)
        try:
            ucd2.open()
            files = ucd2.list_files(http_port=http_port, wait_seconds=30)
            lines.append(f"UCD2 (Luna Ultra): OK ({len(files)} files)")
        except UCD2Error as exc:
            lines.append(f"UCD2 (Luna Ultra): NG ({exc})")
        finally:
            ucd2.close()
    except ImportError as exc:
        lines.append(f"UCD2 (Luna Ultra): NG (module missing: {exc})")

    tcp = TCPClient(host=host, port=tcp_port, log=log)
    try:
        tcp.open()
        lines.append("Legacy TCP (ONE RS): session OK")
        try:
            files = tcp.list_all_files(http_port=http_port)
            lines.append(f"Legacy TCP GetFileList: OK ({len(files)} files)")
        except Insta360Error as exc:
            lines.append(f"Legacy TCP GetFileList: NG ({exc})")
    except Insta360Error as exc:
        lines.append(f"Legacy TCP session: NG ({exc})")
    finally:
        tcp.close()

    if osc_ok:
        try:
            files = osc.list_all_files()
            lines.append(f"OSC listFiles: OK ({len(files)} files)")
        except Insta360Error as exc:
            lines.append(f"OSC listFiles: NG ({exc})")

    return lines


# Insta360 公式アプリ (FFmpeg/Lavf) が送るヘッダー。UCD2 セッション中の HTTP GET に必須。
CAMERA_HTTP_USER_AGENT = "Lavf/60.3.100"


def build_camera_download_request(
    url: str, range_start: int | None = 0
) -> urllib.request.Request:
    headers = {
        "User-Agent": CAMERA_HTTP_USER_AGENT,
        "Accept": "*/*",
        "Connection": "close",
        "Icy-MetaData": "1",
    }
    if range_start is not None:
        headers["Range"] = f"bytes={range_start}-"
    return urllib.request.Request(url, method="GET", headers=headers)


def build_camera_probe_request(url: str) -> urllib.request.Request:
    return urllib.request.Request(
        url,
        method="GET",
        headers={
            "User-Agent": CAMERA_HTTP_USER_AGENT,
            "Accept": "*/*",
            "Connection": "close",
            "Range": "bytes=0-0",
            "Icy-MetaData": "1",
        },
    )


@dataclass
class Insta360Session:
    """カメラ接続セッション。UCD2/TCP はダウンロード完了まで開いたまま維持する。"""

    protocol: str
    host: str
    files: list[CameraFile]
    _ucd2: object | None = field(default=None, repr=False)
    _tcp: TCPClient | None = field(default=None, repr=False)
    log: ClientLog | None = field(default=None, repr=False)

    def close(self) -> None:
        if self._ucd2 is not None:
            close = getattr(self._ucd2, "close", None)
            if callable(close):
                close()
            self._ucd2 = None
        if self._tcp is not None:
            self._tcp.close()
            self._tcp = None

    def download_file(self, file: CameraFile, destination_dir: str, timeout: int = 300) -> str:
        listed_paths = {item.source_path for item in self.files}
        return download_file(
            file,
            destination_dir,
            timeout=timeout,
            session=self,
            listed_paths=listed_paths,
        )

    def __enter__(self) -> Insta360Session:
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()


def open_session(
    host: str = DEFAULT_HOST,
    tcp_port: int = DEFAULT_TCP_PORT,
    http_port: int = DEFAULT_HTTP_PORT,
    log: ClientLog | None = None,
) -> Insta360Session:
    log = log or ClientLog()
    attempts: list[str] = []

    log.info(f"[1/3] UCD2 (Luna Ultra 等) {host}:{tcp_port} を試行...")
    try:
        from insta360_ucd2 import UCD2Client, UCD2Error

        ucd2 = UCD2Client(host=host, port=tcp_port, log=log)
        try:
            ucd2.open()
            log.info("  UCD2 接続成功")
            files = ucd2.list_files(http_port=http_port, wait_seconds=30)
            log.info(f"  UCD2 で {len(files)} 件のファイルを取得")
            camera_files = [
                CameraFile(
                    source_path=f.source_path,
                    download_url=f.download_url,
                    name=f.name,
                    storage=f.storage,
                    size=f.size,
                    capture_time=f.capture_time,
                )
                for f in files
            ]
            camera_files = discover_companion_dng_files(
                camera_files,
                host=host,
                http_port=http_port,
                log=log,
            )
            return Insta360Session(
                protocol="ucd2",
                host=host,
                files=camera_files,
                _ucd2=ucd2,
                log=log,
            )
        except UCD2Error as exc:
            detail = str(exc)
            attempts.append(f"UCD2/{tcp_port}: {detail}")
            log.info(f"  UCD2 失敗: {detail}")
            ucd2.close()
    except ImportError as exc:
        attempts.append(f"UCD2: {exc}")
        log.info(f"  UCD2 モジュール未使用: {exc}")

    log.info(f"[2/3] Legacy TCP {host}:{tcp_port} を試行...")
    tcp = TCPClient(host=host, port=tcp_port, log=log)
    try:
        tcp.open()
        log.info("  TCP 接続成功")
        files = tcp.list_all_files(http_port=http_port)
        log.info(f"  TCP で {len(files)} 件のファイルを取得")
        return Insta360Session(protocol="tcp", host=host, files=files, _tcp=tcp, log=log)
    except Insta360Error as exc:
        detail = str(exc)
        attempts.append(f"TCP/{tcp_port}: {detail}")
        log.info(f"  TCP 失敗: {detail}")
        tcp.close()
    except OSError as exc:
        detail = str(exc)
        attempts.append(f"TCP/{tcp_port}: {detail}")
        log.info(f"  TCP 失敗: {detail}")
        tcp.close()

    log.info(f"[3/3] OSC HTTP {host}:{http_port} を試行...")
    osc = OSCClient(host=host, http_port=http_port, log=log)
    osc_ok, osc_detail = osc.probe()
    if not osc_ok:
        attempts.append(f"OSC HTTP/{http_port}/osc/info: {osc_detail}")
        log.info(f"  OSC 利用不可: {osc_detail}")
        summary = "\n".join(f"  - {item}" for item in attempts)
        raise Insta360Error(
            f"{host} への接続に失敗しました。\n{summary}\n"
            "詳細は --verbose / --probe を再実行してください。",
            attempts=attempts,
        )

    log.info(f"  OSC 利用可能: {osc_detail}")
    try:
        files = osc.list_all_files()
        log.info(f"  OSC で {len(files)} 件のファイルを取得")
        return Insta360Session(protocol="osc", host=host, files=files, log=log)
    except Insta360Error as exc:
        attempts.append(f"OSC listFiles: {exc}")
        log.info(f"  OSC listFiles 失敗: {exc}")
        summary = "\n".join(f"  - {item}" for item in attempts)
        raise Insta360Error(
            f"{host} への接続に失敗しました。\n{summary}\n"
            "詳細は --verbose / --probe を再実行してください。",
            attempts=attempts,
        ) from exc


def connect_and_list_files(
    host: str = DEFAULT_HOST,
    tcp_port: int = DEFAULT_TCP_PORT,
    http_port: int = DEFAULT_HTTP_PORT,
    log: ClientLog | None = None,
) -> tuple[str, list[CameraFile]]:
    with open_session(host=host, tcp_port=tcp_port, http_port=http_port, log=log) as session:
        return session.protocol, session.files


def _download_file_once(
    file: CameraFile,
    destination_dir: str,
    timeout: int,
    *,
    session: Insta360Session,
) -> str:
    local_name = file.local_name
    destination = f"{destination_dir.rstrip('/')}/{local_name}"
    last_error: Exception | None = None
    for use_range in (True, False):
        request = build_camera_download_request(
            file.download_url,
            range_start=0 if use_range else None,
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                status = getattr(response, "status", response.getcode())
                if status not in (200, 206):
                    raise Insta360Error(f"HTTP {status} for {file.display_name}")
                with open(destination, "wb") as handle:
                    while True:
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        handle.write(chunk)
            return destination
        except urllib.error.HTTPError as exc:
            last_error = exc
            if exc.code == 401 and session.protocol == "ucd2":
                raise Insta360Error(
                    f"HTTP 401: {file.display_name} — UCD2 セッションが切れている可能性があります。"
                    " 一覧取得後に session.close() していないか確認してください。"
                ) from exc
            if exc.code == 404 and file.storage == "internal":
                raise Insta360Error(
                    f"HTTP 404: {file.display_name} — 本体ストレージのパスが不正な可能性があります。"
                    f" ({file.source_path})"
                ) from exc
            if use_range and exc.code in (416, 405):
                continue
            raise Insta360Error(f"HTTP {exc.code}: {file.display_name}") from exc
        except (OSError, urllib.error.URLError) as exc:
            last_error = exc
            if use_range:
                continue
            raise Insta360Error(f"保存失敗 ({local_name}): {exc}") from exc

    raise Insta360Error(f"ダウンロード失敗 ({file.display_name}): {last_error}")


def probe_remote_file(url: str, timeout: int = 10) -> bool:
    request = build_camera_probe_request(url)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status in (200, 206)
    except urllib.error.HTTPError as exc:
        return exc.code in (200, 206)
    except (OSError, urllib.error.URLError):
        return False


def infer_companion_dng_files(
    files: list[CameraFile],
    *,
    host: str,
    http_port: int = DEFAULT_HTTP_PORT,
    log: ClientLog | None = None,
) -> list[CameraFile]:
    """Add expected SD JPG companion DNG paths missing from the UCD2 list."""
    from insta360_paths import build_download_url, companion_raw_path

    listed_paths = {file.source_path for file in files}
    extras: list[CameraFile] = []
    for file in files:
        if file.storage != "sd":
            continue
        raw_path = companion_raw_path(file.source_path)
        if raw_path is None or raw_path in listed_paths:
            continue
        listed_paths.add(raw_path)
        extras.append(
            CameraFile(
                source_path=raw_path,
                download_url=build_download_url(host, http_port, raw_path),
                name=raw_path.rsplit("/", 1)[-1],
                storage="sd",
                capture_time=file.capture_time,
            )
        )
        if log is not None:
            log.debug(f"inferred companion DNG: {raw_path}")
    if extras and log is not None:
        log.info(f"  SD JPG から DNG を {len(extras)} 件推定追加")
    return files + extras


def discover_companion_dng_files(
    files: list[CameraFile],
    *,
    host: str,
    http_port: int = DEFAULT_HTTP_PORT,
    log: ClientLog | None = None,
) -> list[CameraFile]:
    return infer_companion_dng_files(
        files,
        host=host,
        http_port=http_port,
        log=log,
    )


def download_file(
    file: CameraFile,
    destination_dir: str,
    timeout: int = 300,
    *,
    session: Insta360Session | None = None,
    listed_paths: set[str] | None = None,
) -> str:
    if session is None:
        raise Insta360Error(
            "ダウンロードには open_session() で開いたセッションが必要です。"
            " UCD2 では TCP/6666 接続を維持しないと HTTP が 401 になります。"
        )

    destination = _download_file_once(file, destination_dir, timeout, session=session)
    from insta360_paths import build_download_url, companion_raw_path

    raw_path = companion_raw_path(file.source_path)
    if raw_path is None:
        return destination
    raw_url = build_download_url(session.host, DEFAULT_HTTP_PORT, raw_path)
    in_list = listed_paths is not None and raw_path in listed_paths
    if not in_list and not probe_remote_file(raw_url, timeout=min(timeout, 10)):
        return destination
    raw_file = CameraFile(
        source_path=raw_path,
        download_url=raw_url,
        name=raw_path.rsplit("/", 1)[-1],
        storage=file.storage,
        capture_time=file.capture_time,
    )
    try:
        _download_file_once(raw_file, destination_dir, timeout, session=session)
        if session.log is not None:
            session.log.info(f"  companion DNG: {raw_file.name}")
    except Insta360Error as exc:
        if session.log is not None:
            session.log.debug(f"companion DNG skipped ({raw_file.name}): {exc}")
    return destination
