#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unsigned local DMG packaging for release rehearsal (Phase 5). Does NOT sign or notarize.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DERIVED="${DERIVED:-$ROOT/.build/DerivedData}"
OUT_DIR="${OUT_DIR:-$ROOT/Artifacts/release}"
APP_NAME="DownloadManager"
VERSION="${MARKETING_VERSION:-0.1.0}"

mkdir -p "$OUT_DIR"
cd "$ROOT"

make project
xcodebuild -project DownloadManager.xcodeproj -scheme DownloadManager \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" build

APP="$(find "$DERIVED/Build/Products/Release" -name "${APP_NAME}.app" -maxdepth 2 | head -n1)"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "error: Release app not found under $DERIVED" >&2
  exit 1
fi

STAGE="$OUT_DIR/dmg-stage"
DMG="$OUT_DIR/${APP_NAME}-${VERSION}-unsigned.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/${APP_NAME}.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
echo "wrote unsigned DMG: $DMG"
echo "Community distribution (ADR 0008): not Developer ID signed. See Documentation/install-from-github.md"
echo "Optional later: Scripts/release/notarize.sh after credentials (not required for GitHub releases)."
