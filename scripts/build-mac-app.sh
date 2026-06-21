#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC_APP="$ROOT/apps/mac-app"
BUILD_DIR="$MAC_APP/.build/debug"
APP_NAME="Insta360Sync"
APP_BUNDLE="$MAC_APP/.build/${APP_NAME}.app"

cd "$MAC_APP"
"$ROOT/scripts/build-pwa.sh"
swift build

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$MAC_APP/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp -R "$MAC_APP/Sources/Insta360Sync/Resources/public" "$APP_BUNDLE/Contents/Resources/public"

# 位置情報など TCC ダイアログ表示には .app への署名が必要
if codesign --force --deep --sign - --timestamp=none "$APP_BUNDLE" 2>/dev/null; then
  echo "Signed $APP_BUNDLE (ad-hoc)"
else
  echo "warning: codesign failed; location permission dialog may not appear" >&2
fi

echo "Built $APP_BUNDLE"
