#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unsigned local DMG packaging for release rehearsal (Phase 5). Does NOT sign or notarize.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DERIVED="${DERIVED:-$ROOT/.build/DerivedData}"
OUT_DIR="${OUT_DIR:-$ROOT/Artifacts/release}"
PRODUCT_NAME="DownloadManager"
DISPLAY_APP_NAME="Flow Download Manager"
VERSION="${MARKETING_VERSION:-$(tr -d '[:space:]' <"$ROOT/VERSION")}"

mkdir -p "$OUT_DIR"
cd "$ROOT"

make project
xcodebuild -project DownloadManager.xcodeproj -scheme DownloadManager \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  build

APP="$(find "$DERIVED/Build/Products/Release" -name "${PRODUCT_NAME}.app" -maxdepth 2 | head -n1)"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "error: Release app not found under $DERIVED" >&2
  exit 1
fi

STAGE="$OUT_DIR/dmg-stage"
DMG="$OUT_DIR/${PRODUCT_NAME}-${VERSION}-unsigned.dmg"
SHA="$DMG.sha256"
rm -rf "$STAGE" "$DMG" "$SHA"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/${DISPLAY_APP_NAME}.app"
STAGED_APP="$STAGE/${DISPLAY_APP_NAME}.app"
ENTITLEMENTS="$ROOT/Configuration/DownloadManager.entitlements"

# Ad-hoc re-seal: sign nested Sparkle helpers, then the app with entitlements.
# `--deep` alone drops/mis-applies entitlements; sign the app last explicitly.
SPARKLE="$STAGED_APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  codesign --force --sign - --options runtime "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  codesign --force --sign - --options runtime "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  codesign --force --sign - --options runtime "$SPARKLE/Versions/B/Updater.app"
  codesign --force --sign - --options runtime "$SPARKLE/Versions/B/Autoupdate"
  codesign --force --sign - --options runtime "$SPARKLE"
fi
for helper in \
  "$STAGED_APP/Contents/XPCServices/DownloadEngineAgent.xpc" \
  "$STAGED_APP/Contents/MacOS/DownloadEngineAgent" \
  "$STAGED_APP/Contents/MacOS/ChromeNativeHost"; do
  if [[ -e "$helper" ]]; then
    if [[ -f "$ENTITLEMENTS" ]]; then
      codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$helper"
    else
      codesign --force --sign - --options runtime "$helper"
    fi
  fi
done
if [[ -f "$ENTITLEMENTS" ]]; then
  codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$STAGED_APP"
else
  codesign --force --sign - "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"

ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Flow Download Manager" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
shasum -a 256 "$DMG" | awk '{print $1 "  " $2}' >"$SHA"
# Rewrite checksum line to basename-only for portable verify
(
  cd "$(dirname "$DMG")"
  shasum -a 256 "$(basename "$DMG")" >"$(basename "$SHA")"
)

echo "wrote unsigned DMG: $DMG"
echo "wrote checksum:     $SHA"
echo "Community distribution (ADR 0008): not Developer ID signed. See Documentation/install-from-github.md"
echo "Optional later: Scripts/release/notarize.sh after credentials (not required for GitHub releases)."
