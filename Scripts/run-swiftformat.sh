#!/usr/bin/env bash
# Run the repo-pinned SwiftFormat binary only. Never fall through to Homebrew /
# image-preinstalled SwiftFormat (macos runners currently ship 0.62.x, whose
# default rules fail format-check on this tree).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/Tools/bin/swiftformat"
PIN="0.59.1"
CONFIG="$ROOT/.swiftformat"

if [[ ! -x "$BIN" ]]; then
    echo "error: missing pinned swiftformat at $BIN (run: make bootstrap-tools)" >&2
    exit 1
fi

have="$("$BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"
if [[ "$have" != "$PIN" ]]; then
    echo "error: expected swiftformat $PIN at $BIN, got '${have:-unknown}'" >&2
    exit 1
fi

mode="${1:-}"
shift || true
case "$mode" in
    --lint|lint)
        echo "swiftformat $have lint ($BIN)"
        # --lint must not be followed by path args (0.59.1 treats the next
        # token as an unexpected value). Keep flags together, paths last.
        # --cache ignore: do not reuse a cache written by a different version.
        exec "$BIN" --lint --cache ignore --config "$CONFIG" "$@"
        ;;
    --format|format|"")
        echo "swiftformat $have format ($BIN)"
        exec "$BIN" --cache ignore --config "$CONFIG" "$@"
        ;;
    *)
        echo "usage: $0 [--lint|lint|--format|format] <paths...>" >&2
        exit 2
        ;;
esac
