#!/usr/bin/env bash
# Record a performance baseline with the exact machine/OS/toolchain
# (05-quality-testing-release-gates.md §5, 08-validation-commands.md §11).
# Writes an immutable timestamped candidate; never overwrites approved baselines.
# CI from unlike machines is not compared against this baseline.
set -euo pipefail
cd "$(dirname "$0")/.."

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="Artifacts/baselines"
OUT="${OUT_DIR}/candidate-${STAMP}.json"
LATEST="${OUT_DIR}/candidate-latest.json"
BUNDLE="Artifacts/validation/latest/performance.xcresult"
mkdir -p "$OUT_DIR" Artifacts/validation/latest
# xcodebuild refuses to overwrite an existing result bundle.
rm -rf "$BUNDLE"

# This target RECORDS a baseline; it does not gate. Tolerate a nonzero pipeline
# exit (e.g. measurement variance) so the machine descriptor is always written.
xcodebuild -project DownloadManager.xcodeproj -scheme DownloadManager \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
    -only-testing:PerformanceTests \
    -resultBundlePath "$BUNDLE" test 2>&1 \
    | grep -E 'measured|Executed|\[throughput\]' | tail -40 || true

CPU="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
OS="$(sw_vers -productVersion)"
XCODE="$(xcodebuild -version 2>/dev/null | head -1)"
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

METRICS_JSON="{}"
if [[ -d "$BUNDLE" ]]; then
  METRICS_JSON="$(Scripts/extract-performance-metrics.py "$BUNDLE" 2>/dev/null || echo '{}')"
fi

python3 - "$OUT" "$DATE" "$COMMIT" "$CPU" "$MEM_GB" "$OS" "$XCODE" "$BUNDLE" "$METRICS_JSON" <<'PY'
import json, sys
out, date, commit, cpu, mem_gb, os_ver, xcode, bundle, metrics_s = sys.argv[1:]
try:
    metrics = json.loads(metrics_s) if metrics_s.strip() else {}
except json.JSONDecodeError:
    metrics = {}
doc = {
    "recordedAt": date,
    "commit": commit,
    "machine": {"cpu": cpu, "memoryGB": int(mem_gb), "arch": __import__("os").uname().machine},
    "os": os_ver,
    "xcode": xcode,
    "rowCount": 10000,
    "metrics": metrics,
    "resultBundle": bundle,
    "note": (
        "Candidate descriptor. Promote by copying to an approved-* name after review. "
        "Numeric metrics are XCTest measure() averages extracted via xcresulttool."
        if metrics else
        "Candidate descriptor with empty metrics — re-run after a green PerformanceTests pass."
    ),
}
with open(out, "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
print(f"metrics count: {len(metrics)}")
PY

cp "$OUT" "$LATEST"
echo "wrote $OUT"
echo "updated $LATEST"
