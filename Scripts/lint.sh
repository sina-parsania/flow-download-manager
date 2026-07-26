#!/usr/bin/env bash
# Lint gate: pinned SwiftLint (strict) + banned-token/unsafe-pattern backstop
# (05-quality-testing-release-gates.md §6). Never fall through to a Homebrew /
# image-preinstalled SwiftLint — version drift turns metric defaults into CI red.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="$(pwd)/Tools/bin/swiftlint"
PIN="0.57.1"

if [[ ! -x "$BIN" ]]; then
    echo "error: missing pinned swiftlint at $BIN (run: make bootstrap-tools)" >&2
    exit 1
fi

have="$("$BIN" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
if [[ "$have" != "$PIN" ]]; then
    echo "error: expected swiftlint $PIN at $BIN, got '${have:-unknown}'" >&2
    exit 1
fi

echo "swiftlint $have ($BIN)"
# Cache under the repo so sandboxed / read-only home directories cannot break the gate.
mkdir -p .build/swiftlint-cache
"$BIN" lint --strict --config .swiftlint.yml --cache-path .build/swiftlint-cache
echo "lint: swiftlint (strict) OK"

# The grep backstop always runs so incomplete-work stays covered even if lint
# rules are narrowed.
Scripts/incomplete-work-scan.sh
