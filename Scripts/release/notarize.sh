#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Notarization entry point. Fails closed without release credentials (Phase 5).
set -euo pipefail

if [[ -z "${DM_NOTARY_PROFILE:-}" && -z "${APPLE_API_KEY:-}" ]]; then
  cat >&2 <<'EOF'
Notarization is optional (ADR 0008). Community GitHub releases use unsigned DMGs.

This script only runs when you already have Apple credentials:
  DM_NOTARY_PROFILE   # notarytool keychain profile name
  or APPLE_API_KEY + APPLE_API_KEY_ID + APPLE_API_ISSUER

For free distribution: make release-dmg-unsigned
  and Documentation/install-from-github.md
EOF
  exit 2
fi

DMG="${1:-}"
if [[ -z "$DMG" || ! -f "$DMG" ]]; then
  echo "usage: $0 <signed.dmg>" >&2
  exit 1
fi

if [[ -n "${DM_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$DM_NOTARY_PROFILE" --wait
else
  xcrun notarytool submit "$DMG" \
    --key "$APPLE_API_KEY" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" \
    --wait
fi

xcrun stapler staple "$DMG"
echo "notarized and stapled: $DMG"
