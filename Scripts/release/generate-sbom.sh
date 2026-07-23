#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Generate a lightweight SBOM-ish dependency inventory for release evidence.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/Artifacts/release/sbom.txt}"
mkdir -p "$(dirname "$OUT")"

{
  echo "# Download Manager dependency inventory"
  echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## Swift packages (Package.resolved)"
  if [[ -f "$ROOT/Package.resolved" ]]; then
    cat "$ROOT/Package.resolved"
  else
    echo "(missing Package.resolved)"
  fi
  echo
  echo "## Vendored libcurl manifest"
  if [[ -f "$ROOT/VendorBuild/manifests/libcurl.json" ]]; then
    cat "$ROOT/VendorBuild/manifests/libcurl.json"
  fi
} >"$OUT"

echo "wrote $OUT"
