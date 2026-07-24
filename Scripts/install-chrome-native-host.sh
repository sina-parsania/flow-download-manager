#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Registers the Chrome Native Messaging host manifest for Flow Download Manager.
#
# Finds the host binary in an installed app first (~/Applications, /Applications,
# Spotlight), then in a local build. Derives the unpacked extension ID from the
# extension directory path the same way Chrome does, so nothing has to be pasted
# by hand, and writes the manifest for every Chromium-family browser present.
#
# Environment overrides:
#   DM_NATIVE_HOST_PATH    absolute path to the ChromeNativeHost binary
#   DM_APP_PATH            absolute path to an installed .app to take the host from
#   DM_CHROME_EXTENSION_DIR  extension source directory (default BrowserExtension/chrome)
#   DM_CHROME_EXTENSION_ID   extra extension ID(s), comma-separated
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_NAME="org.downloadmanager.local.ChromeNativeHost"
APP_BUNDLE_ID="org.downloadmanager.local.DownloadManager"
EXTENSION_DIR="${DM_CHROME_EXTENSION_DIR:-${ROOT}/BrowserExtension/chrome}"
HOST_BIN="${DM_NATIVE_HOST_PATH:-}"

# --- Locate the host binary --------------------------------------------------

app_candidates=()
if [[ -n "${DM_APP_PATH:-}" ]]; then
  app_candidates+=("${DM_APP_PATH}")
fi
app_candidates+=(
  "${HOME}/Applications/Flow Download Manager.app"
  "/Applications/Flow Download Manager.app"
  "${HOME}/Applications/DownloadManager.app"
  "/Applications/DownloadManager.app"
  "${ROOT}/.build/DerivedData/Build/Products/Debug/DownloadManager.app"
  "${ROOT}/.build/DerivedData/Build/Products/Release/DownloadManager.app"
  "${ROOT}/build/Debug/DownloadManager.app"
  "${ROOT}/build/Release/DownloadManager.app"
)

# Spotlight catches installs in a directory none of the above guessed.
if command -v mdfind >/dev/null 2>&1; then
  while IFS= read -r found; do
    if [[ -n "${found}" ]]; then
      app_candidates+=("${found}")
    fi
  done < <(mdfind "kMDItemCFBundleIdentifier == '${APP_BUNDLE_ID}'" 2>/dev/null || true)
fi

APP_USED=""
if [[ -z "${HOST_BIN}" ]]; then
  for app in "${app_candidates[@]}"; do
    embedded="${app}/Contents/MacOS/ChromeNativeHost"
    if [[ -x "${embedded}" ]]; then
      HOST_BIN="${embedded}"
      APP_USED="${app}"
      break
    fi
  done
fi

if [[ -z "${HOST_BIN}" ]]; then
  for candidate in \
    "${ROOT}/.build/DerivedData/Build/Products/Debug/ChromeNativeHost" \
    "${ROOT}/.build/DerivedData/Build/Products/Release/ChromeNativeHost" \
    "${ROOT}/build/Debug/ChromeNativeHost" \
    "${ROOT}/build/Release/ChromeNativeHost"
  do
    if [[ -x "${candidate}" ]]; then
      HOST_BIN="${candidate}"
      break
    fi
  done
fi

if [[ -z "${HOST_BIN}" || ! -x "${HOST_BIN}" ]]; then
  cat >&2 <<'MSG'
error: could not find the ChromeNativeHost binary.

Install Flow Download Manager (Documentation/install-from-github.md) or build it
locally, then re-run. To point at a specific copy:

  DM_APP_PATH="/Applications/Flow Download Manager.app" Scripts/install-chrome-native-host.sh
  DM_NATIVE_HOST_PATH=/path/to/ChromeNativeHost Scripts/install-chrome-native-host.sh
MSG
  exit 1
fi

if [[ ! -d "${EXTENSION_DIR}" ]]; then
  echo "error: extension directory not found: ${EXTENSION_DIR}" >&2
  exit 1
fi

# --- Resolve the allowed extension origins -----------------------------------
#
# Chrome derives an unpacked extension's ID from the absolute directory path:
# the first 16 bytes of SHA-256(path), each hex digit mapped 0-f onto a-p. Both
# the literal and the symlink-resolved path are registered because Chrome
# canonicalises the path it was given, and the two can differ (/tmp, /Volumes).

DEST_DIRS=()
add_dest() {
  local support="$1"
  if [[ -d "${support}" ]]; then
    DEST_DIRS+=("${support}/NativeMessagingHosts")
  fi
  return 0
}
SUPPORT="${HOME}/Library/Application Support"
add_dest "${SUPPORT}/Google/Chrome"
add_dest "${SUPPORT}/Google/Chrome Beta"
add_dest "${SUPPORT}/Google/Chrome Dev"
add_dest "${SUPPORT}/Google/Chrome Canary"
add_dest "${SUPPORT}/Chromium"
add_dest "${SUPPORT}/BraveSoftware/Brave-Browser"
add_dest "${SUPPORT}/Microsoft Edge"
add_dest "${SUPPORT}/Vivaldi"
add_dest "${SUPPORT}/Arc/User Data"

# No Chromium-family profile yet: still register for stock Chrome so the manifest
# is in place the first time the browser runs.
if [[ ${#DEST_DIRS[@]} -eq 0 ]]; then
  DEST_DIRS+=("${SUPPORT}/Google/Chrome/NativeMessagingHosts")
fi

# Values are passed as argv, never interpolated into the script body, so a path
# containing quotes or newlines cannot alter the program.
python3 "${ROOT}/Scripts/lib/write_native_host_manifest.py" \
  --host-name "${HOST_NAME}" \
  --host-path "${HOST_BIN}" \
  --extension-dir "${EXTENSION_DIR}" \
  --extra-ids "${DM_CHROME_EXTENSION_ID:-}" \
  -- "${DEST_DIRS[@]}"

echo "host  ${HOST_BIN}"
if [[ -n "${APP_USED}" ]]; then
  echo "app   ${APP_USED}"
fi
cat <<MSG

Next: open chrome://extensions, enable Developer mode, "Load unpacked", and pick
  ${EXTENSION_DIR}
If Chrome reports a different ID than the one above, re-run this script with
DM_CHROME_EXTENSION_ID=<that id>.
MSG
