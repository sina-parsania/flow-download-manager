#!/usr/bin/env bash
# Install pinned developer tools. Dev-only: no production target depends on these,
# on Homebrew, or on user PATH (02-architecture.md §15). Verifies minimum versions.
set -euo pipefail

# Minimum tool versions this repository is validated against.
MIN_XCODEGEN="2.44.0"
MIN_SWIFTFORMAT="0.59.0"
MIN_SWIFTLINT="0.57.0"

version_ge() { [ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

ensure() {
    local tool="$1" min="$2"
    if command -v "$tool" >/dev/null 2>&1; then
        local have; have="$("$tool" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
        if version_ge "$have" "$min"; then
            echo "ok:   $tool $have (>= $min)"
        else
            echo "warn: $tool $have < required $min; upgrading" >&2
            brew upgrade "$tool" || true
        fi
    else
        echo "install: $tool"
        brew install "$tool"
    fi
}

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required for developer tooling. See https://brew.sh" >&2
    exit 1
fi

ensure xcodegen "$MIN_XCODEGEN"
ensure swiftformat "$MIN_SWIFTFORMAT"
ensure swiftlint "$MIN_SWIFTLINT"

echo "bootstrap-tools: OK"
