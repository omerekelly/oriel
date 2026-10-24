#!/bin/bash
# Builds Oriel.app from the Swift sources without an Xcode project.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Oriel.app"
BIN="$APP/Contents/MacOS/Oriel"

echo "==> Compiling host"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Host/Info.plist" "$APP/Contents/Info.plist"

swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos14.0 \
  -framework AppKit \
  -framework ScreenCaptureKit \
  -framework VideoToolbox \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework CoreGraphics \
  -framework ApplicationServices \
  -framework Network \
  "$ROOT"/Host/*.swift \
  "$ROOT"/Shared/*.swift \
  -o "$BIN"

echo "==> Signing"
SIGNED=0
while IFS= read -r IDENTITY; do
  [[ -z "$IDENTITY" ]] && continue
  echo "    trying: $IDENTITY"
  if codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP" 2>/dev/null; then
    SIGNED=1
    break
  fi
done < <(security find-identity -v -p codesigning 2>/dev/null \
         | grep -v CSSMERR \
         | grep 'Apple Development' \
         | sed -E 's/.*"(.*)"/\1/')

if [[ "$SIGNED" -eq 0 ]]; then
  echo "    no usable development certificate, ad-hoc signing"
  codesign --force --sign - "$APP"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"
