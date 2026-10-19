#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sign a release .sha256 so Scripts/install.sh can tell a genuine checksum from
# one swapped in alongside a swapped DMG. Writes <file>.sig, then verifies it the
# same way the installer does, against the public key embedded in install.sh —
# so a signing key that does not match the shipped installer fails here, not on
# a user's machine.
#
#   Scripts/release/sign-checksum.sh Artifacts/release/DownloadManager-X-unsigned.dmg.sha256
#
# Key: FLOW_RELEASE_SIGNING_KEY (default ~/.config/flow/release-signing-ed25519).
# Keep a backup: losing it means rotating the key in install.sh and re-signing
# every release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEY="${FLOW_RELEASE_SIGNING_KEY:-$HOME/.config/flow/release-signing-ed25519}"

die() { echo "error: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "usage: $0 <file.sha256>..."
[[ -f "$KEY" ]] || die "release signing key not found at $KEY"

NAMESPACE="$(sed -n 's/^RELEASE_SIGNING_NAMESPACE="\(.*\)"$/\1/p' "$ROOT/Scripts/install.sh")"
EMBEDDED="$(sed -n 's/^RELEASE_SIGNING_KEY="\(.*\)"$/\1/p' "$ROOT/Scripts/install.sh")"
[[ -n "$NAMESPACE" && -n "$EMBEDDED" ]] || die "could not read the signing key from Scripts/install.sh"

# Compare key type + body only; the comment field is free text.
ACTUAL="$(ssh-keygen -y -f "$KEY" | awk '{print $1, $2}')"
[[ "$ACTUAL" == "$(awk '{print $1, $2}' <<<"$EMBEDDED")" ]] \
  || die "signing key does not match the key embedded in Scripts/install.sh"

ALLOWED="$(mktemp)"
trap 'rm -f "$ALLOWED"' EXIT
printf '%s namespaces="%s" %s\n' "$NAMESPACE" "$NAMESPACE" "$EMBEDDED" >"$ALLOWED"

for file in "$@"; do
  [[ -f "$file" ]] || die "not found: $file"
  rm -f "$file.sig"
  ssh-keygen -q -Y sign -f "$KEY" -n "$NAMESPACE" "$file"
  ssh-keygen -Y verify -f "$ALLOWED" -I "$NAMESPACE" -n "$NAMESPACE" -s "$file.sig" <"$file" >/dev/null \
    || die "fresh signature on $file does not verify"
  echo "signed $file.sig"
done
