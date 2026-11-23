#!/usr/bin/env bash
set -euo pipefail

# Copy the signed Insta360Sync.app into /Applications.
# Replaces an existing copy. Restarts the app when it was already running.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Insta360Sync"
SRC="${APP_BUNDLE:-$ROOT/apps/mac-app/.build/${APP_NAME}.app}"
DEST_DIR="${INSTALL_DIR:-/Applications}"
DEST="$DEST_DIR/${APP_NAME}.app"

usage() {
  cat <<'EOF'
Usage:
  install-mac-app.sh [--app /path/to/Insta360Sync.app] [--dest /Applications]

Options:
  --app, -a    Built app bundle (default: apps/mac-app/.build/Insta360Sync.app)
  --dest, -d   Install directory (default: /Applications, or $INSTALL_DIR)
  --help, -h   Show this help.

The bundle must already be signed (make mac-app-signed) so Location
Services permission stays attached to the same Team ID.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app|-a)
      SRC="${2:-}"
      shift 2
      ;;
    --dest|-d)
      DEST_DIR="${2:-}"
      DEST=""
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

DEST="${DEST:-$DEST_DIR/${APP_NAME}.app}"

if [[ ! -d "$SRC" ]]; then
  echo "App bundle not found: $SRC" >&2
  echo "Run: make mac-app-signed" >&2
  exit 1
fi

if ! codesign --verify --deep --strict "$SRC" 2>/dev/null; then
  echo "App is not signed: $SRC" >&2
  echo "Run: make mac-app-signed" >&2
  exit 1
fi

was_running=0
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  was_running=1
  echo "Quitting $APP_NAME..."
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.3
  done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME" || true
    sleep 0.3
  fi
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
codesign --verify --deep --strict "$DEST"

echo "Installed $DEST"

if [[ "$was_running" -eq 1 ]]; then
  echo "Relaunching $DEST"
  open "$DEST"
fi
