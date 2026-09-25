#!/bin/bash
# Builds a self-contained, signed bigvoice.app and a distributable zip.
#   CODESIGN_IDENTITY  Signing identity. Defaults to the first Apple Development or Developer ID
#                      identity in the keychain (stable, so macOS privacy grants survive rebuilds),
#                      falling back to ad-hoc ("-").
#   CONFIGURATION      release (default) or debug.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')"
    IDENTITY="${IDENTITY:--}"
fi

echo "==> Verifying pinned fonts and native runtimes"
(cd Resources/Fonts && shasum -a 256 -c SHA256SUMS >/dev/null)
python3 scripts/bootstrap-onnx.py

echo "==> Building bigvoice ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product bigvoice
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/dist/bigvoice.app"
ONNX="$ROOT/.build/onnx-runtime"
[[ -d "$BIN/whisper.framework" ]] || { echo "The whisper.cpp framework is missing from the build output." >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Fonts" \
         "$APP/Contents/Resources/Licenses" "$ROOT/.build/artwork"
cp "$BIN/bigvoice" "$APP/Contents/MacOS/bigvoice"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ditto --norsrc "$BIN/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
# GenAI dlopens libonnxruntime.dylib from its own directory; both ship as real files, no symlinks.
cp -L "$ONNX/libonnxruntime-genai.dylib" "$ONNX/libonnxruntime.dylib" "$APP/Contents/Frameworks/"
cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
cp Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/"
cp Resources/Licenses/*.txt "$APP/Contents/Resources/Licenses/"
for notice in "$ONNX"/onnxruntime*LICENSE* "$ONNX"/*ThirdPartyNotices*; do
    [[ -f "$notice" ]] && cp "$notice" "$APP/Contents/Resources/Licenses/$(basename "$notice").txt"
done

echo "==> Drawing the app icon"
rm -rf "$ROOT/.build/artwork/bigvoice.iconset"
swift "$ROOT/scripts/GenerateIcon.swift" "$ROOT/.build/artwork/bigvoice.iconset"
iconutil -c icns "$ROOT/.build/artwork/bigvoice.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing with: $IDENTITY"
if [[ "$IDENTITY" == "-" ]]; then
    SIGN=(--force --sign -)
elif [[ "$IDENTITY" == Developer\ ID* ]]; then
    SIGN=(--force --sign "$IDENTITY" --options runtime --timestamp)
else
    SIGN=(--force --sign "$IDENTITY" --options runtime --timestamp=none)
fi
codesign "${SIGN[@]}" "$APP/Contents/Frameworks/libonnxruntime.dylib"
codesign "${SIGN[@]}" "$APP/Contents/Frameworks/libonnxruntime-genai.dylib"
codesign "${SIGN[@]}" "$APP/Contents/Frameworks/whisper.framework"
codesign "${SIGN[@]}" --entitlements Resources/bigvoice.entitlements "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

ZIP="$ROOT/dist/bigvoice-$VERSION-macos-arm64.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
printf '\nBuilt %s (%s)\nPackage %s (%s)\n' "$APP" "$(du -sh "$APP" | cut -f1)" "$ZIP" "$(du -sh "$ZIP" | cut -f1)"
