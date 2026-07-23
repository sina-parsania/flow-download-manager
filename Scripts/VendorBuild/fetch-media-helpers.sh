#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fetch pinned media helpers into VendorBuild/prefix when URLs+checksums are set.
# Binaries stay optional until a capability gate enables shipping them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ARCH="${DM_VENDOR_ARCH:-arm64}"
PREFIX="${ROOT}/VendorBuild/prefix/${ARCH}/media"
MANIFEST_DIR="${ROOT}/VendorBuild/manifests"

mkdir -p "${PREFIX}/bin"

fetch_one() {
  local name="$1"
  local manifest="${MANIFEST_DIR}/${name}.json"
  python3 - <<PY
import json, hashlib, os, sys, urllib.request
from pathlib import Path

manifest = Path(r"""${manifest}""")
doc = json.loads(manifest.read_text(encoding="utf-8"))
url = doc.get("downloadURL")
sha = doc.get("sha256")
out_name = doc.get("binaryName")
if not url or not sha or not out_name:
    print(f"{manifest.name}: pin declared; downloadURL/sha256/binaryName not set — skip")
    sys.exit(0)

dest = Path(r"""${PREFIX}/bin""") / out_name
print(f"fetching {doc['name']} {doc.get('version')} → {dest}")
data = urllib.request.urlopen(url, timeout=120).read()
digest = hashlib.sha256(data).hexdigest()
if digest != sha.lower():
    raise SystemExit(f"checksum mismatch for {out_name}: got {digest}")
dest.write_bytes(data)
dest.chmod(0o755)
print(f"ok {out_name}")
PY
}

fetch_one "ytdlp"
fetch_one "ffmpeg"
echo "media vendor prefix: ${PREFIX}"
