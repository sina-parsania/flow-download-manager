#!/usr/bin/env bash
# Lint gate: syntax-aware Swift rules (SwiftLint strict) when available; always the
# banned-token/unsafe-pattern backstop (05-quality-testing-release-gates.md §6).
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v swiftlint >/dev/null 2>&1; then
    swiftlint lint --strict --config .swiftlint.yml
    echo "lint: swiftlint (strict) OK"
else
    echo "lint: swiftlint not installed; using grep safety backstop."
fi

# The grep backstop runs regardless so `make lint` is meaningful without swiftlint.
Scripts/incomplete-work-scan.sh
