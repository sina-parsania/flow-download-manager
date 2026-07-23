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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/flow-install.XXXXXX")"
MOUNTPOINT=""
cleanup() {
  if [[ -n "${MOUNTPOINT}" ]]; then
    hdiutil detach "${MOUNTPOINT}" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

api_json() {
  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$1"
}

download_release_assets() {
  local release_json dmg_url sha_url
  if [[ -n "$TAG" ]]; then
    release_json="$(api_json "https://api.github.com/repos/${REPO}/releases/tags/${TAG}")"
  else
    release_json="$(api_json "https://api.github.com/repos/${REPO}/releases/latest")"
  fi

  dmg_url="$(RELEASE_JSON="$release_json" PREFIX="$ASSET_PREFIX" SUFFIX="$ASSET_SUFFIX" python3 - <<'PY'
import json, os
data = json.loads(os.environ["RELEASE_JSON"])
prefix, suffix = os.environ["PREFIX"], os.environ["SUFFIX"]
for asset in data.get("assets", []):
    name = asset.get("name") or ""
    if name.startswith(prefix) and name.endswith(suffix) and not name.endswith(".sha256"):
        print(asset["browser_download_url"])
        break
PY
)"
  sha_url="$(RELEASE_JSON="$release_json" PREFIX="$ASSET_PREFIX" SUFFIX="$ASSET_SUFFIX" python3 - <<'PY'
import json, os
data = json.loads(os.environ["RELEASE_JSON"])
prefix, suffix = os.environ["PREFIX"], os.environ["SUFFIX"]
want = suffix + ".sha256"
for asset in data.get("assets", []):
    name = asset.get("name") or ""
    if name.startswith(prefix) and name.endswith(want):
        print(asset["browser_download_url"])
        break
PY
)"

  [[ -n "$dmg_url" ]] || die "no ${ASSET_PREFIX}*${ASSET_SUFFIX} asset on release${TAG:+ ${TAG}}"

  echo "Downloading $(basename "$dmg_url")…"
  curl -fL --progress-bar -o "${WORKDIR}/flow.dmg" "$dmg_url"
  if [[ -n "$sha_url" ]]; then
    curl -fsSL -o "${WORKDIR}/flow.dmg.sha256" "$sha_url"
    echo "Verifying SHA-256…"
    expected="$(awk '{print $1}' "${WORKDIR}/flow.dmg.sha256")"
    actual="$(shasum -a 256 "${WORKDIR}/flow.dmg" | awk '{print $1}')"
    [[ "$expected" == "$actual" ]] || die "checksum mismatch (expected ${expected}, got ${actual})"
    echo "Checksum OK."
  else
    echo "warning: no .sha256 asset published for this release; skipping checksum" >&2
  fi
}

if [[ -n "$LOCAL_DMG" ]]; then
  [[ -f "$LOCAL_DMG" ]] || die "DMG not found: $LOCAL_DMG"
  cp "$LOCAL_DMG" "${WORKDIR}/flow.dmg"
else
  download_release_assets
fi

echo "Mounting DMG…"
attach_out="$(hdiutil attach "${WORKDIR}/flow.dmg" -nobrowse -readonly)"
MOUNTPOINT="$(printf '%s\n' "$attach_out" | awk '/\/Volumes\// {print $NF}' | tail -n1)"
[[ -d "${MOUNTPOINT}" ]] || die "failed to mount DMG"

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
