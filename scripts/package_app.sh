#!/bin/bash
# Package scribe.app for download/install: Release build -> dist/scribe-<version>.zip
# and (with --install) copy to /Applications.
#
# Signing: uses the "scribe-dev" identity if one exists in the keychain
# (create one via Keychain Access > Certificate Assistant > Create a
# Certificate, type "Code Signing" — a stable identity keeps TCC grants
# across app updates). Falls back to ad-hoc signing, which works but makes
# macOS re-ask for Input Monitoring/Microphone after every update.
#
# NOT notarized: sharing beyond this machine requires the recipient to
# right-click > Open on first launch (or a paid Developer ID + notarization).
set -euo pipefail

cd "$(dirname "$0")/.."
NATIVE=native
DIST=dist
DERIVED=$(mktemp -d /tmp/scribe-build.XXXXXX)
trap 'rm -rf "$DERIVED"' EXIT

echo "==> Building Release..."
xcodebuild -project "$NATIVE/Scribe.xcodeproj" -scheme Scribe -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -skipMacroValidation build | grep -E 'error|warning: .*deprecat|BUILD' || true

APP="$DERIVED/Build/Products/Release/Scribe.app"
[ -d "$APP" ] || { echo "build failed: $APP not found"; exit 1; }

if security find-identity -v -p codesigning 2>/dev/null | grep -q scribe-dev; then
  echo "==> Signing with scribe-dev identity (stable TCC)..."
  codesign --force --deep --sign scribe-dev "$APP"
else
  echo "==> No scribe-dev identity found — ad-hoc signing (TCC re-grant needed after updates)."
  codesign --force --deep --sign - "$APP"
fi

VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo dev)
mkdir -p "$DIST"
ZIP="$DIST/scribe-$VERSION.zip"
rm -f "$ZIP"
echo "==> Zipping to $ZIP..."
ditto -c -k --keepParent "$APP" "$ZIP"
du -sh "$ZIP"

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications (quitting running instance)..."
  osascript -e 'tell application "Scribe" to quit' 2>/dev/null || true
  sleep 1
  pkill -x Scribe 2>/dev/null || true
  rm -rf /Applications/Scribe.app
  ditto "$APP" /Applications/Scribe.app
  echo "==> Installed. Launch: open /Applications/Scribe.app"
fi
