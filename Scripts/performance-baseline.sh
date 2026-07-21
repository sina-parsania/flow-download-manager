#!/usr/bin/env bash
# Record a performance baseline with the exact machine/OS/toolchain
# (05-quality-testing-release-gates.md §5, 08-validation-commands.md §11).
# CI from unlike machines is not compared against this baseline.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="Artifacts/baselines/phase0-baseline.json"
mkdir -p "$(dirname "$OUT")" Artifacts/validation/latest
# xcodebuild refuses to overwrite an existing result bundle.
rm -rf Artifacts/validation/latest/performance.xcresult

# This target RECORDS a baseline; it does not gate. Tolerate a nonzero pipeline
# exit (e.g. measurement variance) so the machine descriptor is always written.
xcodebuild -project DownloadManager.xcodeproj -scheme DownloadManager \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
    -only-testing:PerformanceTests \
    -resultBundlePath Artifacts/validation/latest/performance.xcresult test 2>&1 \
    | grep -E 'measured|Executed' | tail -25 || true

CPU="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
MEM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
OS="$(sw_vers -productVersion)"
XCODE="$(xcodebuild -version 2>/dev/null | head -1)"
DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$OUT" <<JSON
{
  "recordedAt": "$DATE",
  "machine": { "cpu": "$CPU", "memoryGB": $MEM_GB, "arch": "$(uname -m)" },
  "os": "$OS",
  "xcode": "$XCODE",
  "rowCount": 10000,
  "resultBundle": "Artifacts/validation/latest/performance.xcresult",
  "note": "XCTest metric values are stored in the result bundle; compare only against a baseline from the same machine class."
}
JSON

echo "wrote $OUT"
