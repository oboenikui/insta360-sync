#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROTO_DIR="$ROOT/vendor/insta360-proto"
OUT_DIR="$ROOT/apps/mac-app/Sources/Insta360Proto"

if ! command -v protoc >/dev/null 2>&1; then
  echo "protoc is required. Install protobuf compiler first." >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

protoc \
  --proto_path="$PROTO_DIR" \
  --swift_out="$OUT_DIR" \
  --swift_opt=Visibility=Public \
  "$PROTO_DIR"/*.proto

echo "Generated Swift protobuf sources in $OUT_DIR"
