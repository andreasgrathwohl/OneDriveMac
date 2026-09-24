#!/bin/bash
# Baut "OneDrive Opener.app" (Universal: Apple Silicon + Intel).
# Voraussetzung: Xcode oder die Command Line Tools (xcode-select --install).
#
#   ./build.sh            → build/OneDrive Opener.app
#   ./build.sh install    → zusätzlich nach /Applications kopieren und bei macOS registrieren
#
# Optionale Umgebungsvariablen:
#   BUNDLE_ID      (Standard: de.onedriveopener.app)
#   SIGN_IDENTITY  z. B. "Developer ID Application: Firma GmbH (TEAMID)"; Standard: ad-hoc
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="OneDrive Opener"
EXEC="OneDriveOpener"
BUNDLE_ID="${BUNDLE_ID:-de.onedriveopener.app}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for ARCH in arm64 x86_64; do
  echo "→ Kompiliere für $ARCH"
  xcrun swiftc -O -parse-as-library -swift-version 5 \
    -target "$ARCH-apple-macos12.0" -sdk "$SDK" \
    -o "$BUILD_DIR/$EXEC-$ARCH" Sources/*.swift
done
lipo -create -output "$APP/Contents/MacOS/$EXEC" "$BUILD_DIR/$EXEC-arm64" "$BUILD_DIR/$EXEC-x86_64"
rm -f "$BUILD_DIR/$EXEC-arm64" "$BUILD_DIR/$EXEC-x86_64"

sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    -e "s/__VERSION__/$VERSION/" \
    -e "s/__BUILD__/$BUILD_NUMBER/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

echo "→ Erzeuge App-Icon"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
if xcrun swift Tools/MakeIcon.swift "$ICONSET_DIR" && \
   iconutil -c icns "$ICONSET_DIR" -o "$APP/Contents/Resources/AppIcon.icns"; then
  echo "✓ App-Icon erzeugt"
else
  echo "⚠ Warnung: App-Icon konnte nicht erzeugt werden – baue ohne Icon weiter"
  rm -f "$APP/Contents/Resources/AppIcon.icns"
fi
rm -rf "$ICONSET_DIR"

echo "→ Signiere ($SIGN_IDENTITY)"
codesign --force --options runtime --timestamp=none --entitlements Resources/OneDriveOpener.entitlements --sign "$SIGN_IDENTITY" "$APP"

echo "✓ Fertig: $APP"

if [[ "${1:-}" == "install" ]]; then
  TARGET="/Applications/$APP_NAME.app"
  osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
  rm -rf "$TARGET"
  cp -R "$APP" "$TARGET"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET"
  echo "✓ Installiert: $TARGET"
  open "$TARGET"
fi
