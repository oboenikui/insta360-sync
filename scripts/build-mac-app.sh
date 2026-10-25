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

# `cp -R src dst` は dst が既存だと src を dst の中に入れてしまうため、
# 事前に削除してから丸ごとコピーする。これをしないと再ビルド時に
# 古い assets（別ハッシュのファイル名）が残り続けて index.html の参照と
# ズレが生じる。
rm -rf "$APP_BUNDLE/Contents/Resources/public"
rm -rf "$APP_BUNDLE/Contents/Resources/ucd2"
cp -R "$MAC_APP/Sources/Insta360Sync/Resources/public" "$APP_BUNDLE/Contents/Resources/public"
cp -R "$MAC_APP/Sources/Insta360Sync/Resources/ucd2" "$APP_BUNDLE/Contents/Resources/ucd2"

# Bundle.module は Contents/Resources/Insta360Sync_Insta360Sync.bundle が無いと
# fatalError する。swift run では SPM がパスを渡すが、.app 起動では同梱が必要。
RESOURCE_BUNDLE_NAME="${APP_NAME}_${APP_NAME}.bundle"
RESOURCE_BUNDLE="$BUILD_DIR/$RESOURCE_BUNDLE_NAME"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Resource bundle not found: $RESOURCE_BUNDLE" >&2
  exit 1
fi
rm -rf "$APP_BUNDLE/Contents/Resources/$RESOURCE_BUNDLE_NAME"
cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/$RESOURCE_BUNDLE_NAME"

echo "Built $APP_BUNDLE"
echo "For stable TCC permissions (Location), run: make mac-app-signed"
