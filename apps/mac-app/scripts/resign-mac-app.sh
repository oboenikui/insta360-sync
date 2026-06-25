#!/usr/bin/env bash
set -euo pipefail

# Re-sign Insta360Sync.app with a stable Apple Development identity
# so TCC permissions (Location Services for SSID) persist across rebuilds.

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/apps/mac-app/.build/Insta360Sync.app}"

usage() {
  cat <<'EOF'
Usage:
  resign-mac-app.sh [--identity "Apple Development: ..."] [--app /path/to/Insta360Sync.app]

Options:
  --identity, -i   Code signing identity. If omitted, first "Apple Development" identity is used.
  --app, -a        App bundle path (default: apps/mac-app/.build/Insta360Sync.app)
  --help, -h       Show this help.

Examples:
  ./apps/mac-app/scripts/resign-mac-app.sh
  ./apps/mac-app/scripts/resign-mac-app.sh --identity "Apple Development: Your Name (TEAMID)"
EOF
}

IDENTITY="${CODESIGN_IDENTITY:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity|-i)
      IDENTITY="${2:-}"
      shift 2
      ;;
    --app|-a)
      APP_BUNDLE="${2:-}"
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

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "App bundle not found: $APP_BUNDLE" >&2
  echo "Run: make mac-app" >&2
  exit 1
fi

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
fi

if [[ -z "$IDENTITY" ]]; then
  echo "No Apple Development identity found." >&2
  echo "Open Xcode once and set Team, or install a development certificate." >&2
  exit 1
fi

echo "Using identity: $IDENTITY"
echo "Signing app: $APP_BUNDLE"

MAIN_BIN="$APP_BUNDLE/Contents/MacOS/Insta360Sync"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"

if [[ ! -f "$MAIN_BIN" || ! -f "$INFO_PLIST" ]]; then
  echo "Unexpected bundle layout. Missing Insta360Sync executable or Info.plist." >&2
  exit 1
fi

codesign --force --timestamp=none --sign "$IDENTITY" "$MAIN_BIN"
codesign --force --deep --options runtime --timestamp=none --sign "$IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "codesign details:"
codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 | awk '/Identifier=|TeamIdentifier=|Signature=/{print}'
echo "Re-sign completed."
