#!/usr/bin/env bash
# Regenerate the resolved dependency/license manifest from Package.resolved
# (06-licensing-security-privacy.md §2). Phase 0 ships exactly one runtime
# dependency: GRDB.swift (MIT).
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-Artifacts/validation/latest/dependency-manifest.json}"
mkdir -p "$(dirname "$OUT")"

# Locate the resolved pins (SwiftPM writes Package.resolved under the project).
RESOLVED="$(find . -name Package.resolved -not -path '*/.build/*' 2>/dev/null | head -1)"
[ -z "$RESOLVED" ] && RESOLVED="$(find .build -name Package.resolved 2>/dev/null | head -1)"

grdb_version="$(grep -A6 'GRDB.swift' "$RESOLVED" 2>/dev/null | grep -oE '"version" : "[0-9.]+"' | head -1 | grep -oE '[0-9.]+' || echo 'unknown')"
grdb_revision="$(grep -A6 'GRDB.swift' "$RESOLVED" 2>/dev/null | grep -oE '"revision" : "[a-f0-9]+"' | head -1 | grep -oE '[a-f0-9]{7,}' || echo 'unknown')"

cat > "$OUT" <<JSON
{
  "generatedFrom": "$RESOLVED",
  "phase": 0,
  "shippedRuntimeDependencies": [
    {
      "name": "GRDB.swift",
      "version": "$grdb_version",
      "revision": "$grdb_revision",
      "expectedVersion": "7.11.1",
      "spdxLicense": "MIT",
      "source": "https://github.com/groue/GRDB.swift",
      "linkRelationship": "static (SwiftPM)",
      "nativeTransitive": "system SQLite only"
    }
  ],
  "developerOnlyTools": ["xcodegen", "swiftformat", "swiftlint"],
  "plannedLaterPhases": ["libcurl", "libtorrent", "yt-dlp", "yt-dlp-ejs", "Deno", "FFmpeg", "Sparkle"]
}
JSON

echo "wrote $OUT (GRDB $grdb_version)"
