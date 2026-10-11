#!/bin/sh
set -eu

VERSION="${1:-3.1.3}"
FRONTEND_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$FRONTEND_DIR/web/vendor/zxing-wasm"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL "https://registry.npmjs.org/zxing-wasm/-/zxing-wasm-$VERSION.tgz" -o "$WORK/zxing-wasm.tgz"
tar -xzf "$WORK/zxing-wasm.tgz" -C "$WORK"

EXPECTED_SHA="$(grep -o 'ZXING_WASM_SHA256=`[0-9a-f]*`' "$WORK/package/dist/iife/reader/index.js" | tr -d '`' | cut -d= -f2)"
ACTUAL_SHA="$(sha256sum "$WORK/package/dist/reader/zxing_reader.wasm" | cut -d' ' -f1)"
if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
  echo "zxing_reader.wasm checksum mismatch: expected $EXPECTED_SHA, got $ACTUAL_SHA" >&2
  exit 1
fi

mkdir -p "$TARGET"
cp "$WORK/package/dist/reader/zxing_reader.wasm" "$TARGET/zxing_reader.wasm"
cp "$WORK/package/LICENSE" "$TARGET/LICENSE"
{
  cat "$WORK/package/dist/iife/reader/index.js"
  printf '\n'
  cat "$FRONTEND_DIR/tool/zxing_local_wasm.js"
} > "$TARGET/reader.js"

echo "zxing-wasm $VERSION -> $TARGET"
