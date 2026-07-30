#!/usr/bin/env bash
# Build / refresh the Sparkle appcast from a directory of release archives.
#
# Prerequisites:
#   - Sparkle 2.x tools on PATH or SPARKLE_BIN set to …/Sparkle-*/bin
#   - EdDSA private key already in the login Keychain (`generate_keys`)
#   - Release archives named so generate_appcast can infer versions
#     (e.g. Flow-0.3.0.zip containing Flow Download Manager.app)
#
# Usage:
#   SPARKLE_BIN=~/…/bin ./Scripts/release/sparkle-appcast.sh Artifacts/release/sparkle
#
# Does not upload anything. Commit docs/appcast.xml and attach the zip to the
# GitHub Release after review. Never commit private keys.
set -euo pipefail
cd "$(dirname "$0")/../.."

ARCHIVE_DIR="${1:-}"
if [[ -z "${ARCHIVE_DIR}" || ! -d "${ARCHIVE_DIR}" ]]; then
  echo "usage: $0 <directory-with-release-zips>" >&2
  exit 2
fi

# Pass a directory holding ONLY the current release's zip (+ its .md notes).
#
# Every release uploads its zip to its own tag, so one --download-url-prefix
# cannot be correct for a directory of mixed versions: older entries would be
# rewritten to point at the new tag, where their files do not exist. Sparkle
# only needs the newest entry to offer an update, and older entries in the feed
# serve no purpose once their assets are unreachable.
ARCHIVE_COUNT="$(find "${ARCHIVE_DIR}" -maxdepth 1 -name '*.zip' | wc -l | tr -d ' ')"
if [[ "${ARCHIVE_COUNT}" != "1" ]]; then
  echo "error: expected exactly one .zip in ${ARCHIVE_DIR}, found ${ARCHIVE_COUNT}" >&2
  echo "       stage only the current release — see the comment above." >&2
  exit 2
fi

BIN="${SPARKLE_BIN:-}"
if [[ -z "${BIN}" ]]; then
  if command -v generate_appcast >/dev/null 2>&1; then
    GEN="$(command -v generate_appcast)"
  else
    echo "error: set SPARKLE_BIN to Sparkle’s bin/ directory, or put generate_appcast on PATH" >&2
    exit 2
  fi
else
  GEN="${BIN}/generate_appcast"
fi

if [[ ! -x "${GEN}" ]]; then
  echo "error: generate_appcast not found at ${GEN}" >&2
  exit 2
fi

OUT="docs/appcast.xml"
mkdir -p docs

# Enclosure URLs MUST point at GitHub Release assets. Left to itself,
# generate_appcast writes URLs relative to the output file — i.e.
# raw.githubusercontent.com/.../docs/Flow-X.Y.Z.zip — and the zips are never
# committed to docs/, so every one of those is a 404 and Check for Updates
# fails with a download error. This is the same class of bug that made 0.3.3
# unable to update.
VERSION="$(tr -d '[:space:]' <VERSION)"
TAG="${RELEASE_TAG:-v${VERSION}}"
PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/sina-parsania/flow-download-manager/releases/download/${TAG}/}"

# No binary deltas. They would need uploading as separate assets, and a delta
# referenced by the appcast but missing from the release is another 404 — for
# an ad-hoc build the signing identity differs every release anyway, so
# generate_appcast warns and Sparkle would fall back to the full zip.
"${GEN}" "${ARCHIVE_DIR}" -o "${OUT}" \
  --download-url-prefix "${PREFIX}" \
  --maximum-deltas 0

# Fail closed rather than publish a feed that 404s.
if grep -q 'url="https://raw\.githubusercontent\.com' "${OUT}"; then
  echo "error: ${OUT} still contains raw.githubusercontent.com enclosure URLs" >&2
  echo "       those resolve to files that are never committed — fix the prefix" >&2
  exit 1
fi
if grep -q '\.delta"' "${OUT}"; then
  echo "error: ${OUT} references .delta files that are not uploaded" >&2
  exit 1
fi

echo "wrote ${OUT} (enclosures under ${PREFIX})"
echo "Attach the same archives to the GitHub Release, then commit ${OUT}."
