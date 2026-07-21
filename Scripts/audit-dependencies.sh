#!/usr/bin/env bash
# Verify the resolved dependency graph matches the exact Phase 0 pins
# (06-licensing-security-privacy.md §2). Fails on drift or unexpected packages.
set -euo pipefail
cd "$(dirname "$0")/.."

RESOLVED="$(find . -name Package.resolved -not -path '*/.build/*' 2>/dev/null | head -1)"
[ -z "$RESOLVED" ] && RESOLVED="$(find .build -name Package.resolved 2>/dev/null | head -1)"
[ -z "$RESOLVED" ] && { echo "audit-dependencies: no Package.resolved found" >&2; exit 1; }

EXPECTED_GRDB="7.11.1"
GOT_GRDB="$(grep -A6 'GRDB.swift' "$RESOLVED" | grep -oE '"version" : "[0-9.]+"' | head -1 | grep -oE '[0-9.]+' || true)"

fail=0
if [ "$GOT_GRDB" != "$EXPECTED_GRDB" ]; then
    echo "audit-dependencies: GRDB pin mismatch — expected $EXPECTED_GRDB, got '${GOT_GRDB:-none}'" >&2
    fail=1
else
    echo "ok: GRDB.swift $GOT_GRDB matches exact pin"
fi

# Exactly one shipped runtime dependency (GRDB) is expected in Phase 0.
COUNT="$(grep -c '"identity"' "$RESOLVED" 2>/dev/null || echo 0)"
if [ "$COUNT" -ne 1 ]; then
    echo "audit-dependencies: expected 1 resolved package (GRDB), found $COUNT" >&2
    echo "  (a new dependency requires a manifest/license/CVE entry — see DEPENDENCIES.md)" >&2
    fail=1
else
    echo "ok: exactly one resolved runtime package"
fi

[ "$fail" -eq 0 ] && echo "audit-dependencies: OK"
exit "$fail"
