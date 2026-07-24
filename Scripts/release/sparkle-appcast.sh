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
"${GEN}" "${ARCHIVE_DIR}" -o "${OUT}"
echo "wrote ${OUT}"
echo "Commit ${OUT} and attach the same archives to the GitHub Release."
