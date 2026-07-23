#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Installs the Chrome Native Messaging host manifest for local development.
# Prefers the host embedded in DownloadManager.app when present.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_BIN="${DM_NATIVE_HOST_PATH:-}"
EXTENSION_ID="${DM_CHROME_EXTENSION_ID:-}"
APP_CANDIDATES=(
  "${ROOT}/.build/DerivedData/Build/Products/Debug/DownloadManager.app"
  "${ROOT}/build/Debug/DownloadManager.app"
)

if [[ -z "${HOST_BIN}" ]]; then
  for APP in "${APP_CANDIDATES[@]}"; do
    EMBEDDED="${APP}/Contents/MacOS/ChromeNativeHost"
    if [[ -x "${EMBEDDED}" ]]; then
      HOST_BIN="${EMBEDDED}"
      break
    fi
  done
fi

if [[ -z "${HOST_BIN}" ]]; then
  for CANDIDATE in \
    "${ROOT}/.build/DerivedData/Build/Products/Debug/ChromeNativeHost" \
    "${ROOT}/build/Debug/ChromeNativeHost"
  do
    if [[ -x "${CANDIDATE}" ]]; then
      HOST_BIN="${CANDIDATE}"
      break
    fi
  done
fi

if [[ -z "${HOST_BIN}" || ! -x "${HOST_BIN}" ]]; then
  echo "error: set DM_NATIVE_HOST_PATH or build DownloadManager / ChromeNativeHost first" >&2
  exit 1
fi

if [[ -z "${EXTENSION_ID}" ]]; then
  echo "error: set DM_CHROME_EXTENSION_ID to the unpacked extension ID from chrome://extensions" >&2
  exit 1
fi

DEST_DIR="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts"
mkdir -p "${DEST_DIR}"
DEST="${DEST_DIR}/org.downloadmanager.local.ChromeNativeHost.json"

python3 - <<PY
import json
from pathlib import Path
doc = {
    "name": "org.downloadmanager.local.ChromeNativeHost",
    "description": "Download Manager Chrome Native Messaging host",
    "path": r"""${HOST_BIN}""",
    "type": "stdio",
    "allowed_origins": [f"chrome-extension://${EXTENSION_ID}/"],
}
Path(r"""${DEST}""").write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")
print(f"wrote {Path(r'''${DEST}''')}")
print(f"host  {r'''${HOST_BIN}'''}")
PY
