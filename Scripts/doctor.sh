#!/usr/bin/env bash
# Environment/toolchain report (08-validation-commands.md §1). Fails on Intel or an
# unsupported deployment/toolchain combination. Prints signing identity STATUS only,
# never private key material.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
say() { printf '%-22s %s\n' "$1" "$2"; }

os_ver="$(sw_vers -productVersion)"
arch="$(uname -m)"
say "macOS" "$os_ver"
say "arch" "$arch"

if [ "$arch" != "arm64" ]; then
    echo "FAIL: Intel/x86_64 is unsupported; this project is arm64-only." >&2
    fail=1
fi

os_major="${os_ver%%.*}"
if [ "$os_major" -lt 14 ]; then
    echo "FAIL: macOS 14.0+ required (found $os_ver)." >&2
    fail=1
fi

say "Xcode" "$(xcodebuild -version 2>/dev/null | paste -sd' ' -)"
say "Swift" "$(swift --version 2>/dev/null | head -1)"
say "Clang" "$(clang --version 2>/dev/null | head -1)"
say "SDK" "$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"

if command -v xcodegen >/dev/null 2>&1; then
    say "xcodegen" "$(xcodegen --version 2>/dev/null | head -1)"
else
    echo "FAIL: required dev tool 'xcodegen' not found (run: make bootstrap-tools)." >&2
    fail=1
fi

# Prefer the exact pin under Tools/bin — PATH alone is not enough on CI images
# that already ship Homebrew SwiftFormat 0.62.x.
pinned_sf="$(pwd)/Tools/bin/swiftformat"
if [[ -x "$pinned_sf" ]]; then
    say "swiftformat" "$("$pinned_sf" --version 2>/dev/null | head -1) (pinned: $pinned_sf)"
elif command -v swiftformat >/dev/null 2>&1; then
    say "swiftformat" "$(swiftformat --version 2>/dev/null | head -1) ($(command -v swiftformat); WARNING: not Tools/bin pin)"
    echo "FAIL: pinned Tools/bin/swiftformat missing (run: make bootstrap-tools)." >&2
    fail=1
else
    echo "FAIL: required dev tool 'swiftformat' not found (run: make bootstrap-tools)." >&2
    fail=1
fi
if command -v swiftlint >/dev/null 2>&1; then
    say "swiftlint" "$(swiftlint --version 2>/dev/null)"
else
    say "swiftlint" "absent (grep backstop in use; install via make bootstrap-tools)"
fi

# Signing identity status only (counts), no names/hashes exported.
id_count="$(security find-identity -v -p codesigning 2>/dev/null | grep -cE 'Developer ID Application' || true)"
say "DeveloperID identities" "$id_count present (release-only; not required for dev)"

# Test-service capability: loopback + a writable scratch root.
if [ -w "." ]; then say "test-service scratch" "writable (.build/test-services)"; fi

if [ "$fail" -ne 0 ]; then
    echo "doctor: FAILED" >&2
    exit 1
fi
echo "doctor: OK"
