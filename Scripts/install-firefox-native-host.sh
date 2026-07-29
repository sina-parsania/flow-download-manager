#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Register the Firefox Native Messaging host for Flow Download Manager.
#
# Simpler than the Chrome installer on purpose: Firefox identifies an extension
# by the fixed `browser_specific_settings.gecko.id` in its manifest, so there is
# no unpacked-directory path to hash and no per-Chromium-flavour profile list.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_NAME="org.downloadmanager.local.chrome_native_host"
MANIFEST="${ROOT}/BrowserExtension/firefox/manifest.json"

# The id the host will trust. Read from the manifest so the two can never
# disagree; DM_FIREFOX_EXTENSION_ID overrides for a fork with its own id.
if [[ -n "${DM_FIREFOX_EXTENSION_ID:-}" ]]; then
  EXTENSION_ID="${DM_FIREFOX_EXTENSION_ID}"
else
  if [[ ! -f "${MANIFEST}" ]]; then
    echo "error: manifest not found: ${MANIFEST}" >&2
    exit 1
  fi
  EXTENSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["browser_specific_settings"]["gecko"]["id"])' "${MANIFEST}")"
fi

if [[ -z "${EXTENSION_ID}" ]]; then
  echo "error: could not determine the Firefox extension id" >&2
  exit 1
fi

# Locate the native host binary the same way the Chrome installer does.
HOST_BIN="${DM_NATIVE_HOST_BIN:-}"
if [[ -z "${HOST_BIN}" ]]; then
  for candidate in \
    "${ROOT}/.build/DerivedData/Build/Products/Debug/ChromeNativeHost" \
    "${ROOT}/build/ChromeNativeHost" \
    "${HOME}/Applications/DownloadManager.app/Contents/MacOS/ChromeNativeHost" \
    "/Applications/DownloadManager.app/Contents/MacOS/ChromeNativeHost"; do
    if [[ -x "${candidate}" ]]; then
      HOST_BIN="${candidate}"
      break
    fi
  done
fi

if [[ -z "${HOST_BIN}" || ! -x "${HOST_BIN}" ]]; then
  cat >&2 <<'MSG'
error: native host binary not found.
Build it first (make build-debug) or install the app, then re-run.
Override the location with DM_NATIVE_HOST_BIN=/path/to/ChromeNativeHost.
MSG
  exit 1
fi

# Firefox reads one directory, unlike the Chromium family's per-flavour dirs.
DEST="${HOME}/Library/Application Support/Mozilla/NativeMessagingHosts"

# Values are passed as argv, never interpolated into the script body, so a path
# containing quotes or newlines cannot alter the program.
python3 "${ROOT}/Scripts/lib/write_native_host_manifest.py" \
  --host-name "${HOST_NAME}" \
  --host-path "${HOST_BIN}" \
  --flavor firefox \
  --extra-ids "${EXTENSION_ID}" \
  -- "${DEST}"

echo "host  ${HOST_BIN}"
cat <<MSG

Next: run "make browser-extension-firefox", then open
  about:debugging#/runtime/this-firefox
choose "Load Temporary Add-on" and pick manifest.json inside
  ${ROOT}/.build/firefox-extension
MSG
