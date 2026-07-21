#!/usr/bin/env bash
# Assemble the Phase 0 evidence bundle (05-quality-testing-release-gates.md §13).
# Contains no secrets; paths are recorded in the handoff.
set -euo pipefail
cd "$(dirname "$0")/.."

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DIR="Artifacts/validation/phase0/$TS"
mkdir -p "$DIR"

Scripts/doctor.sh > "$DIR/environment.txt" 2>&1 || true
git status --porcelain=v1 > "$DIR/git-status.txt" 2>&1 || true
Scripts/dependency-manifest.sh "$DIR/dependency-manifest.json" > /dev/null 2>&1 || true
Scripts/incomplete-work-scan.sh > "$DIR/banned-token-scan.txt" 2>&1 || true

# Copy the latest build/test logs and artifacts if present.
for f in build.log full-test.log ui-build.log smappservice-probe.txt; do
    [ -f "Artifacts/validation/latest/$f" ] && cp "Artifacts/validation/latest/$f" "$DIR/" || true
done
[ -d "Artifacts/validation/latest/stable-tests.xcresult" ] && cp -R "Artifacts/validation/latest/stable-tests.xcresult" "$DIR/" || true
[ -f "THIRD_PARTY_NOTICES.md" ] && cp "THIRD_PARTY_NOTICES.md" "$DIR/license-report.md" || true
[ -f "Documentation/accessibility-report.md" ] && cp "Documentation/accessibility-report.md" "$DIR/accessibility-report.md" || true

cat > "$DIR/summary.md" <<SUMMARY
# Phase 0 evidence — $TS

- environment.txt        toolchain / signing-status report
- git-status.txt         working tree state
- dependency-manifest.json exact resolved runtime dependencies (GRDB 7.11.1, MIT)
- banned-token-scan.txt  first-party incomplete-work / unsafe-pattern scan
- full-test.log          unit + integration + recovery + performance results
- stable-tests.xcresult  test result bundle
- smappservice-probe.txt LaunchAgent SMAppService probe (BLOCKED on Developer ID signing)
- license-report.md      third-party notices
- accessibility-report.md accessibility state and manual-script status

This bundle contains no secrets, private URLs, cookies, headers or signing identities.
SUMMARY

ln -sfn "$TS" "Artifacts/validation/phase0/latest" 2>/dev/null || true
echo "evidence bundle: $DIR"
