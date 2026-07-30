#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# One-command release: gate, build, publish, and make in-app updates actually
# work. Replaces a hand-run sequence that shipped two silent failures in one
# afternoon — a DMG whose app reported the previous version, and an appcast
# whose download URLs 404'd. Both are now checked here rather than remembered.
#
#   Scripts/release/publish.sh 0.4.1
#   DRY_RUN=1 Scripts/release/publish.sh 0.4.1   # everything local, nothing pushed
#
# Requires: gh (authenticated), Sparkle tools, the EdDSA key in the Keychain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>   e.g. $0 0.4.1" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be X.Y.Z, got '$VERSION'" >&2
  exit 2
fi
TAG="v${VERSION}"
DRY_RUN="${DRY_RUN:-}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
# Every check here is one a human skips when they are confident.

say "Preflight"

[[ -n "$(git status --porcelain)" ]] && die "working tree is dirty — commit or stash first"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "release from main, currently on '$BRANCH'"

git fetch origin --tags --quiet
if git rev-parse "$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists locally"
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  die "release $TAG already exists on GitHub"
fi
if [[ -n "$(git log origin/main..HEAD --oneline)" ]]; then
  die "local main has unpushed commits — push them first so the tag matches origin"
fi

command -v gh >/dev/null || die "gh not found"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

SPARKLE_BIN="${SPARKLE_BIN:-$ROOT/.build/artifacts/sparkle/Sparkle/bin}"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || die "generate_appcast not found under $SPARKLE_BIN"

# Prove the EdDSA key is reachable BEFORE building for ten minutes. Signing a
# throwaway file is the only way to find out; generate_keys -p only prints the
# public half.
printf 'probe' >/tmp/dm-sparkle-probe.$$
if ! "$SPARKLE_BIN/sign_update" /tmp/dm-sparkle-probe.$$ >/dev/null 2>&1; then
  rm -f /tmp/dm-sparkle-probe.$$
  die "Sparkle EdDSA private key is not in the Keychain — in-app updates cannot be signed"
fi
rm -f /tmp/dm-sparkle-probe.$$

# The key that signs must match the key baked into the app, or every existing
# install rejects the update as tampered.
PUB_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null | tr -d '[:space:]')"
BAKED_KEY="$(sed -n 's/^[[:space:]]*SUPublicEDKey:[[:space:]]*\(.*\)$/\1/p' project.yml | tr -d '[:space:]')"
[[ "$PUB_KEY" == "$BAKED_KEY" ]] || die "Sparkle key mismatch — keychain=$PUB_KEY app=$BAKED_KEY"

grep -q "^## ${VERSION} " CHANGELOG.md || die "CHANGELOG.md has no '## ${VERSION}' section"

echo "ok — releasing $TAG from $(git rev-parse --short HEAD)"

# ------------------------------------------------------------------- gates
# RULE 0: verify-fast is not the gate. A release touches everything.

say "Gates"
make verify-fast
make test-integration
make test-recovery

# ------------------------------------------------------------------- version

say "Version bump"
echo "$VERSION" >VERSION
BUILD="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*"\{0,1\}\([0-9][0-9]*\)"\{0,1\}[[:space:]]*$/\1/p' project.yml | head -n1)"
NEXT_BUILD=$((BUILD + 1))
/usr/bin/sed -i '' \
  -e "s/^\([[:space:]]*\)MARKETING_VERSION: .*/\1MARKETING_VERSION: \"${VERSION}\"/" \
  -e "s/^\([[:space:]]*\)CURRENT_PROJECT_VERSION: .*/\1CURRENT_PROJECT_VERSION: \"${NEXT_BUILD}\"/" \
  project.yml
make project >/dev/null
echo "$VERSION (build $NEXT_BUILD)"

# ------------------------------------------------------------------- build
# build-dmg.sh refuses to package if the built app reports a different version
# than requested, which is what caught the 0.4.0 mis-plumbing.

say "Build"
make release-sbom
make release-dmg-unsigned

DMG="Artifacts/release/DownloadManager-${VERSION}-unsigned.dmg"
[[ -f "$DMG" ]] || die "expected $DMG"

# --------------------------------------------------------------- sparkle zip
# Cut from the app INSIDE the DMG, not from a fresh build, so the bytes users
# update to are the bytes that were packaged and tested.

say "Sparkle archive"
MOUNT="$(mktemp -d)"
hdiutil attach -nobrowse -quiet -mountpoint "$MOUNT" "$DMG"
STAGE="$(mktemp -d)"
ditto "$MOUNT/Flow Download Manager.app" "$STAGE/Flow Download Manager.app"
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT" 2>/dev/null || true

codesign --verify --deep --strict "$STAGE/Flow Download Manager.app" \
  || die "signature broken after copying out of the DMG"
BUILT="$(defaults read "$STAGE/Flow Download Manager.app/Contents/Info.plist" CFBundleShortVersionString)"
[[ "$BUILT" == "$VERSION" ]] || die "app in the DMG reports $BUILT, expected $VERSION"

ZIP_DIR="Artifacts/release/sparkle"
mkdir -p "$ZIP_DIR"
ZIP="$ZIP_DIR/Flow-${VERSION}.zip"
rm -f "$ZIP"
( cd "$STAGE" && ditto -c -k --sequesterRsrc --keepParent "Flow Download Manager.app" "$ROOT/$ZIP" )
rm -rf "$STAGE"

# Release notes for the in-app updater. Extracted from the changelog section so
# there is one source of truth and no second file to forget.
NOTES="$ZIP_DIR/Flow-${VERSION}.md"
{
  echo "## Flow ${VERSION}"
  echo
  awk -v v="## ${VERSION} " '
    index($0, v) == 1 { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  ' CHANGELOG.md
  echo
  echo "Community build — not Apple notarized."
} >"$NOTES"

# ------------------------------------------------------------------ publish

if [[ -n "$DRY_RUN" ]]; then
  say "DRY_RUN — stopping before anything leaves this machine"
  echo "built:  $DMG"
  echo "        $ZIP"
  echo "Revert with: git checkout VERSION project.yml && make project"
  exit 0
fi

say "Publish"
git add VERSION project.yml
git commit -q -m "release: v${VERSION} (build ${NEXT_BUILD})

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main
git tag -a "$TAG" -m "${TAG}"
git push origin "$TAG"

gh release create "$TAG" --title "$TAG" --notes-file "$NOTES" \
  "$DMG" "${DMG}.sha256" "$ZIP"

# --------------------------------------------------------------- appcast
# LAST, and only after the zip is uploaded: the feed points at a release asset,
# so publishing it first would advertise a URL that does not resolve yet.

say "Appcast"
CURRENT="$(mktemp -d)"
cp "$ZIP" "$NOTES" "$CURRENT/"
SPARKLE_BIN="$SPARKLE_BIN" RELEASE_TAG="$TAG" bash Scripts/release/sparkle-appcast.sh "$CURRENT"
rm -rf "$CURRENT"

# Prove the feed is usable before committing it. A feed whose enclosure 404s or
# whose signature disagrees is worse than a stale one: the app reports a failed
# update instead of quietly staying put.
FEED_URL="$(grep -oE 'url="[^"]*Flow-'"${VERSION}"'\.zip"' docs/appcast.xml | head -1 | sed 's/url="//;s/"$//')"
[[ -n "$FEED_URL" ]] || die "appcast has no enclosure for ${VERSION}"
VERIFY="$(mktemp -d)"
curl -sL "$FEED_URL" -o "$VERIFY/check.zip" || die "could not download $FEED_URL"
FEED_SIG="$(grep -oE 'sparkle:edSignature="[^"]*"' docs/appcast.xml | head -1)"
REAL_SIG="$("$SPARKLE_BIN/sign_update" "$VERIFY/check.zip" | grep -oE 'sparkle:edSignature="[^"]*"')"
rm -rf "$VERIFY"
[[ "$FEED_SIG" == "$REAL_SIG" ]] \
  || die "signature mismatch between the appcast and the published zip"

git add docs/appcast.xml "$ZIP_DIR/Flow-${VERSION}.md"
git commit -q -m "release: publish the v${VERSION} appcast

Verified against the live asset: downloaded the enclosure URL and confirmed the
EdDSA signature matches the feed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push origin main

say "Done"
echo "release:  https://github.com/sina-parsania/flow-download-manager/releases/tag/$TAG"
echo "appcast:  serving ${VERSION} (build ${NEXT_BUILD}) — existing installs will be offered it"
