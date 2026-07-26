#!/usr/bin/env bash
# Verify the resolved dependency graph matches the exact pins in DEPENDENCIES.md
# (06-licensing-security-privacy.md §2). Fails on drift or unexpected packages.
set -euo pipefail
cd "$(dirname "$0")/.."

# Prefer the repo-root pin file; never pick a transitive Package.resolved from a
# checkout under .build/.
RESOLVED=""
if [[ -f Package.resolved ]]; then
    RESOLVED="Package.resolved"
else
    RESOLVED="$(find . -name Package.resolved -not -path '*/.build/*' 2>/dev/null | head -1 || true)"
fi
[ -z "$RESOLVED" ] && { echo "audit-dependencies: no Package.resolved found" >&2; exit 1; }

pin_version() {
    local identity="$1"
    # Package.resolved v3: identity block then state.version a few lines below.
    grep -A8 "\"identity\" : \"${identity}\"" "$RESOLVED" \
        | grep -oE '"version" : "[0-9.]+"' \
        | head -1 \
        | grep -oE '[0-9.]+' \
        || true
}

EXPECTED_GRDB="7.11.1"
EXPECTED_SPARKLE="2.9.4"
GOT_GRDB="$(pin_version 'grdb.swift')"
GOT_SPARKLE="$(pin_version 'sparkle')"

fail=0
if [ "$GOT_GRDB" != "$EXPECTED_GRDB" ]; then
    echo "audit-dependencies: GRDB pin mismatch — expected $EXPECTED_GRDB, got '${GOT_GRDB:-none}'" >&2
    fail=1
else
    echo "ok: GRDB.swift $GOT_GRDB matches exact pin"
fi

if [ "$GOT_SPARKLE" != "$EXPECTED_SPARKLE" ]; then
    echo "audit-dependencies: Sparkle pin mismatch — expected $EXPECTED_SPARKLE, got '${GOT_SPARKLE:-none}'" >&2
    fail=1
else
    echo "ok: Sparkle $GOT_SPARKLE matches exact pin"
fi

# Shipped SPM runtime packages: GRDB + Sparkle (see DEPENDENCIES.md).
COUNT="$(grep -c '"identity"' "$RESOLVED" 2>/dev/null || echo 0)"
if [ "$COUNT" -ne 2 ]; then
    echo "audit-dependencies: expected 2 resolved packages (GRDB, Sparkle), found $COUNT" >&2
    echo "  (a new dependency requires a manifest/license/CVE entry — see DEPENDENCIES.md)" >&2
    fail=1
else
    echo "ok: exactly two resolved runtime packages (GRDB, Sparkle)"
fi

[ "$fail" -eq 0 ] && echo "audit-dependencies: OK"
exit "$fail"
