#!/usr/bin/env bash
# Install pinned developer tools. Dev-only: no production target depends on these,
# on Homebrew, or on user PATH (02-architecture.md §15). Verifies exact/minimum
# versions so CI and local machines cannot silently drift onto a newer SwiftFormat
# rule set that fails format-check without rewriting the tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_BIN="$ROOT/Tools/bin"
mkdir -p "$TOOLS_BIN"
export PATH="$TOOLS_BIN:$PATH"

# Exact pins — CI must use these binaries, not "whatever Homebrew last shipped".
PINNED_XCODEGEN="2.44.1"
PINNED_SWIFTFORMAT="0.59.1"
PINNED_SWIFTLINT="0.57.1"

# Minimums kept for tools we still install via brew when an exact pin is awkward.
MIN_XCODEGEN="2.44.0"
MIN_SWIFTLINT="0.57.0"

version_ge() { [ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

tool_version() {
    local tool="$1"
    "$tool" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

ensure_brew_min() {
    local tool="$1" min="$2"
    if command -v "$tool" >/dev/null 2>&1; then
        local have; have="$(tool_version "$tool")"
        if version_ge "$have" "$min"; then
            echo "ok:   $tool $have (>= $min)"
            return
        fi
        echo "warn: $tool $have < required $min; upgrading" >&2
        brew upgrade "$tool" || true
    else
        echo "install: $tool"
        if ! brew install "$tool"; then
            echo "error: failed to install $tool via Homebrew" >&2
            exit 1
        fi
    fi
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool missing after bootstrap" >&2
        exit 1
    fi
    local have; have="$(tool_version "$tool")"
    if ! version_ge "$have" "$min"; then
        echo "error: $tool $have still < required $min" >&2
        exit 1
    fi
    echo "ok:   $tool $have (>= $min)"
}

# Prefer a repo-local exact binary so runners with Homebrew 0.62.x do not fail
# format-check on rules our tree was never rewritten for. Always fetch the
# GitHub release asset (never mirror Homebrew bottles — same version string,
# different bytes) and verify sha256.
SWIFTFORMAT_SHA256_0_59_1="4736bcacfbda0e0316997855934f184fa6399e315f79a8e9d309b3ca28201920"

ensure_swiftformat_exact() {
    local want="$1"
    local dest="$TOOLS_BIN/swiftformat"
    local want_sha="$SWIFTFORMAT_SHA256_0_59_1"

    if [[ "$want" != "0.59.1" ]]; then
        echo "error: no sha256 pin recorded for swiftformat $want; update bootstrap-tools.sh" >&2
        exit 1
    fi

    if [[ -x "$dest" ]]; then
        local have have_sha
        have="$(tool_version "$dest")"
        have_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
        if [[ "$have" == "$want" && "$have_sha" == "$want_sha" ]]; then
            echo "ok:   swiftformat $have (pinned in Tools/bin, sha256 verified)"
            return
        fi
        echo "warn: replacing Tools/bin/swiftformat ($have / ${have_sha:0:12}…) with release $want" >&2
    fi

    local arch
    arch="$(uname -m)"
    case "$arch" in
        arm64) ;;
        *)
            echo "error: SwiftFormat pin requires arm64 (got $arch)" >&2
            exit 1
            ;;
    esac

    local tmp found have have_sha
    tmp="$(mktemp -d)"
    echo "install: swiftformat ${want} (exact pin) → Tools/bin"
    # 0.59.x ships a plain `swiftformat.zip` macOS binary.
    curl -fsSL "https://github.com/nicklockwood/SwiftFormat/releases/download/${want}/swiftformat.zip" \
        -o "$tmp/swiftformat.zip"
    unzip -q "$tmp/swiftformat.zip" -d "$tmp/out"
    found="$(find "$tmp/out" -type f -name swiftformat | head -1)"
    if [[ -z "$found" ]]; then
        echo "error: swiftformat binary missing from release zip $want" >&2
        rm -rf "$tmp"
        exit 1
    fi
    install -m 755 "$found" "$dest"
    # curl-downloaded binaries often carry quarantine; clear so CI/make can exec.
    xattr -cr "$dest" 2>/dev/null || true
    rm -rf "$tmp"

    have_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
    if [[ "$have_sha" != "$want_sha" ]]; then
        echo "error: swiftformat $want sha256 mismatch at $dest" >&2
        echo "error: expected $want_sha" >&2
        echo "error: got      $have_sha" >&2
        exit 1
    fi

    have="$(tool_version "$dest")"
    if [[ "$have" != "$want" ]]; then
        echo "error: expected swiftformat $want, got $have at $dest" >&2
        exit 1
    fi
    echo "ok:   swiftformat $have (pinned in Tools/bin, sha256 verified)"
}

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required for developer tooling. See https://brew.sh" >&2
    exit 1
fi

ensure_brew_min xcodegen "$MIN_XCODEGEN"
ensure_swiftformat_exact "$PINNED_SWIFTFORMAT"
ensure_brew_min swiftlint "$MIN_SWIFTLINT"

# Record pins for doctor / humans.
cat > "$ROOT/Tools/pins.txt" <<EOF
xcodegen>=${MIN_XCODEGEN} (preferred ${PINNED_XCODEGEN})
swiftformat=${PINNED_SWIFTFORMAT} (sha256 ${SWIFTFORMAT_SHA256_0_59_1})
swiftlint>=${MIN_SWIFTLINT} (preferred ${PINNED_SWIFTLINT})
EOF

echo "bootstrap-tools: OK (PATH prefers $TOOLS_BIN)"
