#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install Flow Download Manager from a GitHub Release (unsigned community DMG).
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sina-parsania/flow-download-manager/main/Scripts/install.sh | bash
#   ./Scripts/install.sh [--tag v0.2.0] [--system] [--dir DIR] [--no-open] [--dmg PATH]
set -euo pipefail

REPO="${FLOW_REPO:-sina-parsania/flow-download-manager}"
ASSET_PREFIX="DownloadManager-"
ASSET_SUFFIX="-unsigned.dmg"
APP_BUNDLE_NAME="Flow Download Manager.app"
PRODUCT_APP_NAME="DownloadManager.app"

# Public half of the release signing key. publish.sh signs each DMG's .sha256
# with the private half, which never leaves the maintainer's machine, so a
# replaced DMG + checksum on GitHub fails here. This script itself is the root
# of trust: anyone who can change this line could change everything below it.
# Rotating the key means changing this line AND re-signing every release.
RELEASE_SIGNING_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILfxPMGAU7b/YzH1eZHp9kxAkZU7ZQbgOYC9MDgNabMH"
RELEASE_SIGNING_NAMESPACE="flow-release"

TAG=""
INSTALL_PARENT="${HOME}/Applications"
NEED_SUDO=0
OPEN_AFTER=1
LOCAL_DMG=""

usage() {
  cat <<'EOF'
Install Flow Download Manager from GitHub Releases (community unsigned DMG).

Usage: install.sh [options]

  --tag TAG       Release tag (default: latest)
  --system        Install to /Applications (may prompt for admin)
  --dir DIR       Install parent directory (default: ~/Applications)
  --no-open       Do not launch the app after install
  --dmg PATH      Use a local DMG instead of downloading
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:?}"
      shift 2
      ;;
    --system)
      INSTALL_PARENT="/Applications"
      NEED_SUDO=1
      shift
      ;;
    --dir)
      INSTALL_PARENT="${2:?}"
      NEED_SUDO=0
      shift 2
      ;;
    --no-open)
      OPEN_AFTER=0
      shift
      ;;
    --dmg)
      LOCAL_DMG="${2:?}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

arch="$(uname -m)"
[[ "$arch" == "arm64" ]] || die "Flow requires Apple Silicon (arm64); found ${arch}"

major="$(sw_vers -productVersion | awk -F. '{print $1}')"
[[ "${major}" -ge 14 ]] || die "Flow requires macOS 14 or later"

require_cmd curl
require_cmd hdiutil
require_cmd ditto
require_cmd shasum
require_cmd python3
require_cmd ssh-keygen

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/flow-install.XXXXXX")"
MOUNTPOINT=""
cleanup() {
  if [[ -n "${MOUNTPOINT}" ]]; then
    hdiutil detach "${MOUNTPOINT}" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# Prints the download URL of the first "${ASSET_PREFIX}*<suffix>" asset, or nothing.
asset_url() {
  RELEASE_JSON="$1" PREFIX="$ASSET_PREFIX" SUFFIX="$2" python3 - <<'PY'
import json, os
data = json.loads(os.environ["RELEASE_JSON"])
prefix, suffix = os.environ["PREFIX"], os.environ["SUFFIX"]
for asset in data.get("assets", []):
    name = asset.get("name") or ""
    if name.startswith(prefix) and name.endswith(suffix):
        print(asset["browser_download_url"])
        break
PY
}

api_json() {
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$1"
}

download_release_assets() {
  local release_json dmg_url sha_url sig_url
  if [[ -n "$TAG" ]]; then
    release_json="$(api_json "https://api.github.com/repos/${REPO}/releases/tags/${TAG}")"
  else
    release_json="$(api_json "https://api.github.com/repos/${REPO}/releases/latest")"
  fi

  dmg_url="$(asset_url "$release_json" "$ASSET_SUFFIX")"
  sha_url="$(asset_url "$release_json" "${ASSET_SUFFIX}.sha256")"
  sig_url="$(asset_url "$release_json" "${ASSET_SUFFIX}.sha256.sig")"

  [[ -n "$dmg_url" ]] || die "no ${ASSET_PREFIX}*${ASSET_SUFFIX} asset on release${TAG:+ ${TAG}}"

  echo "Downloading $(basename "$dmg_url")…"
  # Fail closed: every release carries a .sha256 and its signature. A missing one
  # means a broken or tampered release, not an old one. `--dmg` is the escape hatch.
  [[ -n "$sha_url" ]] || die "no .sha256 asset on release${TAG:+ ${TAG}}; refusing to install unverified DMG"
  [[ -n "$sig_url" ]] || die "no .sha256.sig asset on release${TAG:+ ${TAG}}; refusing to install unverified DMG"
  curl -fsSL -o "${WORKDIR}/flow.dmg.sha256" "$sha_url"
  curl -fsSL -o "${WORKDIR}/flow.dmg.sha256.sig" "$sig_url"
  echo "Verifying release signature…"
  printf '%s namespaces="%s" %s\n' "$RELEASE_SIGNING_NAMESPACE" "$RELEASE_SIGNING_NAMESPACE" \
    "$RELEASE_SIGNING_KEY" >"${WORKDIR}/allowed_signers"
  ssh-keygen -Y verify -f "${WORKDIR}/allowed_signers" -I "$RELEASE_SIGNING_NAMESPACE" \
    -n "$RELEASE_SIGNING_NAMESPACE" -s "${WORKDIR}/flow.dmg.sha256.sig" \
    <"${WORKDIR}/flow.dmg.sha256" >/dev/null 2>&1 \
    || die "release signature does not verify; refusing to install"
  echo "Signature OK."
  curl -fL --progress-bar -o "${WORKDIR}/flow.dmg" "$dmg_url"
  echo "Verifying SHA-256…"
  expected="$(awk '{print $1}' "${WORKDIR}/flow.dmg.sha256")"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "malformed .sha256 asset"
  actual="$(shasum -a 256 "${WORKDIR}/flow.dmg" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || die "checksum mismatch (expected ${expected}, got ${actual})"
  echo "Checksum OK."
}

if [[ -n "$LOCAL_DMG" ]]; then
  [[ -f "$LOCAL_DMG" ]] || die "DMG not found: $LOCAL_DMG"
  cp "$LOCAL_DMG" "${WORKDIR}/flow.dmg"
else
  download_release_assets
fi

echo "Mounting DMG…"
attach_out="$(hdiutil attach "${WORKDIR}/flow.dmg" -nobrowse -readonly)"
# Volume names may contain spaces — take everything from /Volumes/ onward.
MOUNTPOINT="$(printf '%s\n' "$attach_out" | sed -n 's|.*\(/Volumes/.*\)|\1|p' | tail -n1)"
[[ -d "${MOUNTPOINT}" ]] || die "failed to mount DMG (parsed mount point: '${MOUNTPOINT:-<empty>}')"

SRC_APP=""
if [[ -d "${MOUNTPOINT}/${APP_BUNDLE_NAME}" ]]; then
  SRC_APP="${MOUNTPOINT}/${APP_BUNDLE_NAME}"
elif [[ -d "${MOUNTPOINT}/${PRODUCT_APP_NAME}" ]]; then
  SRC_APP="${MOUNTPOINT}/${PRODUCT_APP_NAME}"
else
  SRC_APP="$(find "${MOUNTPOINT}" -maxdepth 2 -name '*.app' -type d | head -n1 || true)"
fi
[[ -d "${SRC_APP}" ]] || die "no .app found inside DMG"

DEST="${INSTALL_PARENT}/${APP_BUNDLE_NAME}"
echo "Installing to ${DEST}…"
mkdir -p "${INSTALL_PARENT}"

if [[ "$NEED_SUDO" -eq 1 && ! -w "$INSTALL_PARENT" ]]; then
  echo "Admin privileges required for ${INSTALL_PARENT}"
  sudo mkdir -p "$INSTALL_PARENT"
  sudo rm -rf "$DEST"
  sudo ditto "$SRC_APP" "$DEST"
  sudo xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
else
  rm -rf "$DEST"
  ditto "$SRC_APP" "$DEST"
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
fi

echo "Installed Flow Download Manager → ${DEST}"

if [[ "$OPEN_AFTER" -eq 1 ]]; then
  open "$DEST"
fi
