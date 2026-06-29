#!/usr/bin/env python3
"""Insta360 動作検証用 TUI: ファイル一覧の取得・選択・ダウンロード。"""

from __future__ import annotations

import argparse
import curses
import os
import sys
import urllib.error
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from insta360_client import (  # noqa: E402
    DEFAULT_HOST,
    DEFAULT_HTTP_PORT,
    DEFAULT_TCP_PORT,
    CameraFile,
    ClientLog,
    Insta360Error,
    Insta360Session,
    open_session,
    run_probe,
)
from sync_manifest import (  # noqa: E402
    is_synced,
    load_manifest,
    mark_synced,
    save_manifest,
)


def format_size(size: int | None) -> str:
    if size is None:
        return "     ?"
    units = ["B", "KB", "MB", "GB"]
    value = float(size)
    unit = units[0]
    for unit in units:
        if value < 1024 or unit == units[-1]:
            break
        value /= 1024
    if unit == "B":
        return f"{int(value):6d}B"
    return f"{value:6.1f}{unit}"


def draw_screen(
    stdscr: curses.window,
    files: list[CameraFile],
    selected: set[int],
    cursor: int,
    scroll: int,
    status: str,
    protocol: str,
    host: str,
) -> None:
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    header_lines = [
        "Insta360 Sync TUI（動作検証）",
        f"host={host} protocol={protocol} files={len(files)} selected={len(selected)}",
        "↑↓: 移動  Enter/Space: 選択  d: ダウンロード  a: 全選択  n: 解除  q: 終了",
    ]
    footer = status[: max(0, width - 1)]

    row = 0
    for line in header_lines:
        if row >= height - 2:
            break
        stdscr.addnstr(row, 0, line, width - 1, curses.A_BOLD if row == 0 else curses.A_NORMAL)
        row += 1

    list_top = row
    list_height = max(0, height - list_top - 2)
    visible = list_height

    if visible <= 0:
        stdscr.refresh()
        return

    if cursor < scroll:
        scroll = cursor
    if cursor >= scroll + visible:
        scroll = cursor - visible + 1

    for index in range(scroll, min(len(files), scroll + visible)):
        file = files[index]
        marker = "[x]" if index in selected else "[ ]"
        current = index == cursor
        line = f"{marker} {format_size(file.size)}  {file.display_name}"
        attr = curses.A_REVERSE if current else curses.A_NORMAL
        stdscr.addnstr(list_top + index - scroll, 0, line, width - 1, attr)

    if not files:
        stdscr.addnstr(list_top, 0, "ファイルがありません", width - 1)

    stdscr.addnstr(height - 1, 0, footer, width - 1, curses.A_DIM)
    stdscr.refresh()


def run_tui(
    stdscr: curses.window,
    session: Insta360Session,
    destination_dir: str,
) -> None:
    files = session.files
    protocol = session.protocol
    host = session.host
    manifest = load_manifest(destination_dir)
    for file in files:
        file.synced = is_synced(file, manifest)
    curses.curs_set(0)
    stdscr.keypad(True)
    if curses.has_colors():
        curses.use_default_colors()

    selected: set[int] = set()
    cursor = 0
    scroll = 0
    status = "準備完了"

    while True:
        draw_screen(stdscr, files, selected, cursor, scroll, status, protocol, host)
        key = stdscr.getch()

        if key in (curses.KEY_UP, ord("k")):
            cursor = max(0, cursor - 1)
        elif key in (curses.KEY_DOWN, ord("j")):
            cursor = min(max(len(files) - 1, 0), cursor + 1)
        elif key in (curses.KEY_PPAGE,):
            cursor = max(0, cursor - 10)
        elif key in (curses.KEY_NPAGE,):
            cursor = min(max(len(files) - 1, 0), cursor + 10)
        elif key in (curses.KEY_HOME,):
            cursor = 0
        elif key in (curses.KEY_END,):
            cursor = max(len(files) - 1, 0)
        elif key in (ord("\n"), ord("\r"), ord(" ")):
            if files:
                if cursor in selected:
                    selected.remove(cursor)
                    status = f"選択解除: {files[cursor].display_name}"
                else:
                    selected.add(cursor)
                    status = f"選択: {files[cursor].display_name}"
        elif key == ord("a"):
            selected = set(range(len(files)))
            status = f"全選択 ({len(selected)})"
        elif key == ord("n"):
            selected.clear()
            status = "選択を解除しました"
        elif key == ord("d"):
            targets = sorted(selected) if selected else ([cursor] if files else [])
            if not targets:
                status = "ダウンロード対象がありません"
                continue
            ok = 0
            errors: list[str] = []
            for index in targets:
                file = files[index]
                if file.synced:
                    errors.append(f"{file.name}: 同期済みのためスキップ")
                    continue
                status = f"ダウンロード中: {file.display_name}"
                draw_screen(stdscr, files, selected, cursor, scroll, status, protocol, host)
                try:
                    path = session.download_file(file, destination_dir)
                    mark_synced(manifest, file)
                    save_manifest(destination_dir, manifest)
                    file.synced = True
                    ok += 1
                    status = f"保存しました: {path}"
                except (Insta360Error, OSError, urllib.error.URLError) as exc:
                    errors.append(f"{file.name}: {exc}")
            if errors:
                status = f"{ok}/{len(targets)} 件成功。エラー: {errors[0]}"
            else:
                status = f"{ok} 件を {destination_dir} に保存しました"
        elif key in (ord("q"), 27):
            break


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Insta360 camera file browser TUI for manual verification.",
    )
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"Camera IP (default: {DEFAULT_HOST})")
    parser.add_argument("--tcp-port", type=int, default=DEFAULT_TCP_PORT, help="TCP port")
    parser.add_argument("--http-port", type=int, default=DEFAULT_HTTP_PORT, help="HTTP port")
    parser.add_argument(
        "--dest",
        default=os.getcwd(),
        help="Download destination directory (default: current directory)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="count",
        default=0,
        help="詳細ログ (-v: debug, -vv: trace/hex dump)",
    )
    parser.add_argument(
        "--probe",
        action="store_true",
        help="接続診断のみ実行して終了（TUI は起動しない）",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    log = ClientLog(verbose=args.verbose)
    destination_dir = os.path.abspath(args.dest)
    os.makedirs(destination_dir, exist_ok=True)

    if args.probe or args.verbose >= 1:
        print(f"=== Insta360 接続診断 ({args.host}) ===", file=sys.stderr)
        for line in run_probe(
            host=args.host,
            tcp_port=args.tcp_port,
            http_port=args.http_port,
            log=log,
        ):
            print(f"  {line}", file=sys.stderr)
        print("=== 診断終了 ===", file=sys.stderr)
        if args.probe:
            return 0

    print(
        f"Insta360 ({args.host}) に接続中... TCP {args.tcp_port}, HTTP {args.http_port}",
        file=sys.stderr,
    )
    try:
        session = open_session(
            host=args.host,
            tcp_port=args.tcp_port,
            http_port=args.http_port,
            log=log,
        )
    except Insta360Error as exc:
        print(f"エラー: {exc}", file=sys.stderr)
        if exc.attempts:
            print("試行結果:", file=sys.stderr)
            for item in exc.attempts:
                print(f"  - {item}", file=sys.stderr)
        print(
            "ヒント: --probe でポート/プロトコルごとの診断、-v/-vv でより詳細なログを確認できます。",
            file=sys.stderr,
        )
        return 1

    manifest = load_manifest(destination_dir)
    synced_count = 0
    for file in session.files:
        file.synced = is_synced(file, manifest)
        if file.synced:
            synced_count += 1

    print(f"{session.protocol} で接続しました。{len(session.files)} 件のファイル。", file=sys.stderr)
    if synced_count:
        print(f"同期済み: {synced_count} 件（次回スキップ）", file=sys.stderr)
    print(f"保存先: {destination_dir}", file=sys.stderr)

    try:
        curses.wrapper(
            lambda stdscr: run_tui(stdscr, session, destination_dir)
        )
    except KeyboardInterrupt:
        print("\n中断しました。", file=sys.stderr)
        return 130
    finally:
        session.close()
        print("カメラ接続を切断しました。", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
