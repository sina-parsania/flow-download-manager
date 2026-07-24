#!/usr/bin/env bash
# Flow: `make verify-fast` does not run integration, recovery, performance, or the
# sanitizers. A slice once shipped "green on verify-fast" with two segmented-transfer
# integration tests failing. When an edit lands in code those lanes cover, say so.
set -uo pipefail

FILE=$(jq -r '.tool_input.file_path // ""' 2>/dev/null <<<"$(cat)")
[ -n "$FILE" ] || exit 0

case "$FILE" in
  */Sources/TransferCore/*|*/Sources/TransferCurlBridge/*|*/Sources/CCurl/*)
    echo "verify-fast does NOT cover this file. Required before done: make test-integration, make test-recovery, make test-asan, make test-tsan. Changed tiling/concurrency/refill? also make test-performance." >&2
    ;;
  */Sources/EngineAgent/*|*/Sources/Persistence/*|*/Sources/XPCContracts/*)
    echo "verify-fast does NOT cover this file. Required before done: make test-integration, make test-recovery. New DTO? add a case to Tests/Unit/XPCCodingTests.swift and register it in EngineControlInterface.swift." >&2
    ;;
  */project.yml)
    echo "project.yml changed — run 'make project' before building; DownloadManager.xcodeproj is generated and gitignored." >&2
    ;;
esac

exit 0
