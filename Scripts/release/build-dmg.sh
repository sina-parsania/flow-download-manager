#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Unsigned local DMG packaging for release rehearsal (Phase 5). Does NOT sign or notarize.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DERIVED="${DERIVED:-$ROOT/.build/DerivedData}"
OUT_DIR="${OUT_DIR:-$ROOT/Artifacts/release}"
PRODUCT_NAME="DownloadManager"
DISPLAY_APP_NAME="Flow Download Manager"
# Both values come from the same places the Xcode build reads them: VERSION for
# the marketing string, project.yml for the build number. The build number used
# to be read from Configuration/DownloadManager-Info.plist, which carried its own
# hardcoded copy — so a version bump in project.yml was silently ignored and the
# DMG was NAMED 0.4.0 while shipping an app that reported 0.3.5 build 8. The
# plist now interpolates $(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION), so
# there is exactly one source of truth for each.
VERSION="${MARKETING_VERSION:-$(tr -d '[:space:]' <"$ROOT/VERSION")}"
BUILD="${CURRENT_PROJECT_VERSION:-$(
  sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}[[:space:]]*$/\1/p' \
    "$ROOT/project.yml" | head -n1
)}"

if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "error: could not resolve VERSION ('$VERSION') or BUILD ('$BUILD')" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
cd "$ROOT"

make project
xcodebuild -project DownloadManager.xcodeproj -scheme DownloadManager \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  build

APP="$(find "$DERIVED/Build/Products/Release" -name "${PRODUCT_NAME}.app" -maxdepth 2 | head -n1)"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "error: Release app not found under $DERIVED" >&2
  exit 1
fi

# Fail closed on a version mismatch. The DMG filename is built from $VERSION, so
# without this check a stale or mis-plumbed build ships an app reporting a
# different version than the file it arrived in — which is exactly what happened
# once, and is invisible until a user opens About.
BUILT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
BUILT_BUILD="$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$BUILT_VERSION" != "$VERSION" || "$BUILT_BUILD" != "$BUILD" ]]; then
  cat >&2 <<MSG
error: built app does not match the requested version.
  requested: $VERSION ($BUILD)
  built:     ${BUILT_VERSION:-<none>} (${BUILT_BUILD:-<none>})
Check that Configuration/DownloadManager-Info.plist interpolates
\$(MARKETING_VERSION) and \$(CURRENT_PROJECT_VERSION) rather than hardcoding them.
MSG
  exit 1
fi
echo "verified app reports $BUILT_VERSION ($BUILT_BUILD)"

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
