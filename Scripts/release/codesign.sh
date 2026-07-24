#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Optional Developer ID codesign (ADR 0008 Track B). Fails closed without identity.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ -z "${DM_CODESIGN_IDENTITY:-}" ]]; then
  cat >&2 <<'EOF'
Codesigning is optional (ADR 0008). Community GitHub releases ship unsigned.

Set DM_CODESIGN_IDENTITY to a "Developer ID Application: …" identity, then:

  make release-codesign APP=/path/to/DownloadManager.app

For free distribution: make release-dmg-unsigned
EOF
  exit 2
fi

APP="${1:-${APP:-}}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: $0 <DownloadManager.app>" >&2
  exit 1
fi

IDENTITY="$DM_CODESIGN_IDENTITY"

sign() {
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"
}

# Deepest first: XPC service, helpers, then the app bundle.
AGENT_XPC="$APP/Contents/XPCServices/DownloadEngineAgent.xpc"
[[ -d "$AGENT_XPC" ]] && sign "$AGENT_XPC"

NATIVE_HOST="$APP/Contents/MacOS/ChromeNativeHost"
[[ -f "$NATIVE_HOST" ]] && sign "$NATIVE_HOST"

AGENT_BIN="$APP/Contents/MacOS/DownloadEngineAgent"
[[ -f "$AGENT_BIN" ]] && sign "$AGENT_BIN"

sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=4 "$APP" || true
echo "signed: $APP"
