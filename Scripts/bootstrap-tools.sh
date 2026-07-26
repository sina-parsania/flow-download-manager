#!/usr/bin/env bash
# Install pinned developer tools. Dev-only: no production target depends on these,
# on Homebrew, or on user PATH (02-architecture.md §15). Verifies exact versions
# so CI and local machines cannot silently drift onto newer SwiftFormat /
# SwiftLint rule sets that fail the gate without rewriting the tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_BIN="$ROOT/Tools/bin"
mkdir -p "$TOOLS_BIN"
export PATH="$TOOLS_BIN:$PATH"

# Exact pins — CI must use these binaries, not "whatever Homebrew last shipped".
PINNED_XCODEGEN="2.44.1"
PINNED_SWIFTFORMAT="0.59.1"
PINNED_SWIFTLINT="0.57.1"

MIN_XCODEGEN="2.44.0"

SWIFTFORMAT_SHA256_0_59_1="4736bcacfbda0e0316997855934f184fa6399e315f79a8e9d309b3ca28201920"
SWIFTLINT_SHA256_0_57_1="34ddc877b21dcf4ea0ba6a3c7d3770ca5f52b203fb867bffe609aff8e4704ad4"

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

# Fetch a GitHub-released macOS binary into Tools/bin and verify sha256.
install_pinned_binary() {
    local name="$1" want="$2" want_sha="$3" url="$4" zip_member_hint="$5"
    local dest="$TOOLS_BIN/$name"

    if [[ -x "$dest" ]]; then
        local have have_sha
        have="$(tool_version "$dest")"
        have_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
        if [[ "$have" == "$want" && "$have_sha" == "$want_sha" ]]; then
            echo "ok:   $name $have (pinned in Tools/bin, sha256 verified)"
            return
        fi
        echo "warn: replacing Tools/bin/$name ($have / ${have_sha:0:12}…) with release $want" >&2
    fi

    local arch
    arch="$(uname -m)"
    case "$arch" in
        arm64) ;;
        *)
            echo "error: $name pin requires arm64 (got $arch)" >&2
            exit 1
            ;;
    esac

    local tmp found have have_sha
    tmp="$(mktemp -d)"
    echo "install: $name ${want} (exact pin) → Tools/bin"
    curl -fsSL "$url" -o "$tmp/tool.zip"
    unzip -q "$tmp/tool.zip" -d "$tmp/out"
    found="$(find "$tmp/out" -type f -name "$zip_member_hint" | head -1)"
    if [[ -z "$found" ]]; then
        echo "error: $name binary missing from release zip $want" >&2
        rm -rf "$tmp"
        exit 1
    fi
    install -m 755 "$found" "$dest"
    xattr -cr "$dest" 2>/dev/null || true
    rm -rf "$tmp"

    have_sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
    if [[ "$have_sha" != "$want_sha" ]]; then
        echo "error: $name $want sha256 mismatch at $dest" >&2
        echo "error: expected $want_sha" >&2
        echo "error: got      $have_sha" >&2
        exit 1
    fi

    have="$(tool_version "$dest")"
    if [[ "$have" != "$want" ]]; then
        echo "error: expected $name $want, got $have at $dest" >&2
        exit 1
    fi
    echo "ok:   $name $have (pinned in Tools/bin, sha256 verified)"
}

ensure_swiftformat_exact() {
    install_pinned_binary \
        swiftformat \
        "$1" \
        "$SWIFTFORMAT_SHA256_0_59_1" \
        "https://github.com/nicklockwood/SwiftFormat/releases/download/${1}/swiftformat.zip" \
        swiftformat
}

ensure_swiftlint_exact() {
    install_pinned_binary \
        swiftlint \
        "$1" \
        "$SWIFTLINT_SHA256_0_57_1" \
        "https://github.com/realm/SwiftLint/releases/download/${1}/portable_swiftlint.zip" \
        swiftlint
}

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required for developer tooling. See https://brew.sh" >&2
    exit 1
fi

ensure_brew_min xcodegen "$MIN_XCODEGEN"
ensure_swiftformat_exact "$PINNED_SWIFTFORMAT"
ensure_swiftlint_exact "$PINNED_SWIFTLINT"

cat > "$ROOT/Tools/pins.txt" <<EOF
xcodegen>=${MIN_XCODEGEN} (preferred ${PINNED_XCODEGEN})
swiftformat=${PINNED_SWIFTFORMAT} (sha256 ${SWIFTFORMAT_SHA256_0_59_1})
swiftlint=${PINNED_SWIFTLINT} (sha256 ${SWIFTLINT_SHA256_0_57_1})
EOF

echo "bootstrap-tools: OK (PATH prefers $TOOLS_BIN)"
