#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PWA_DIR="$ROOT/apps/pwa"
OUT_DIR="$ROOT/apps/mac-app/Sources/Insta360Sync/Resources/public"

cd "$PWA_DIR"
npm install
npm run build

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -R dist/* "$OUT_DIR"/
cp public/sw.js "$OUT_DIR"/sw.js
cp public/manifest.webmanifest "$OUT_DIR"/manifest.webmanifest
cp public/icon.svg "$OUT_DIR"/icon.svg

echo "PWA copied to $OUT_DIR"
