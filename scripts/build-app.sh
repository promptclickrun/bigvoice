#!/bin/bash
# Builds a self-contained, signed bigvoice.app and a distributable zip.
#   CODESIGN_IDENTITY  Signing identity. Defaults to the first Developer ID Application identity in
#                      the keychain, then Apple Development (stable, so macOS privacy grants survive
#                      rebuilds), falling back to ad-hoc ("-").
#   CONFIGURATION      release (default) or debug.
#   NOTARY_PROFILE     notarytool keychain profile, or NOTARY_KEY_ID + NOTARY_ISSUER (+ NOTARY_KEY_PATH,
#                      default ~/.private_keys/AuthKey_<id>.p8) for an App Store Connect API key.
#                      When set with a Developer ID identity, the app is notarized and stapled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null)"
    IDENTITY="$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<<"$IDENTITIES")"
    [[ -n "$IDENTITY" ]] || IDENTITY="$(awk -F'"' '/Apple Development/ {print $2; exit}' <<<"$IDENTITIES")"
    IDENTITY="${IDENTITY:--}"
fi

echo "==> Verifying pinned fonts and native runtimes"
(cd Resources/Fonts && shasum -a 256 -c SHA256SUMS >/dev/null)
python3 scripts/bootstrap-onnx.py

XCODE_CONFIGURATION="$(tr '[:lower:]' '[:upper:]' <<<"${CONFIGURATION:0:1}")${CONFIGURATION:1}"
if xcodebuild -version >/dev/null 2>&1; then
    echo "==> Building bigvoice with Xcode ($CONFIGURATION)"
    xcodebuild -scheme bigvoice -configuration "$XCODE_CONFIGURATION" -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$ROOT/.build/xcode" -quiet build CODE_SIGNING_ALLOWED=NO
    BIN="$ROOT/.build/xcode/Build/Products/$XCODE_CONFIGURATION"
else
    # Command Line Tools only: SwiftPM produces the same binary and frameworks.
    echo "==> Building bigvoice with SwiftPM ($CONFIGURATION; full Xcode not selected)"
    swift build -c "$CONFIGURATION" --product bigvoice
    BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"
fi
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

NOTARY=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    NOTARY=(--key "${NOTARY_KEY_PATH:-$HOME/.private_keys/AuthKey_$NOTARY_KEY_ID.p8}" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
fi
if [[ ${#NOTARY[@]} -gt 0 && "$IDENTITY" == Developer\ ID* ]]; then
    echo "==> Notarizing"
    xcrun notarytool submit "$ZIP" "${NOTARY[@]}" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi
printf '\nBuilt %s (%s)\nPackage %s (%s)\n' "$APP" "$(du -sh "$APP" | cut -f1)" "$ZIP" "$(du -sh "$ZIP" | cut -f1)"
