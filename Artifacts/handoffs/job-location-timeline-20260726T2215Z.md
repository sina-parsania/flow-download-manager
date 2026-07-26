# Handoff — job location + timeline + Open File

**COMPLETE**

## What shipped
- Persist per-job `destinationPath`, `finalFilename`, `startedAt`, `completedAt` (schema v7).
- `JobSnapshot` carries paths + ISO-8601 timestamps; table shows Started / Finished / Location (sortable).
- Open in Finder uses the job’s stored path (not only the global default folder).
- Open File opens the completed file with the default app (context menu, board, inspector).

## Evidence
```
make verify-fast          # exit 0
make test-integration     # 59 tests, 0 failures
make test-recovery        # 9 tests, 0 failures
```

## Not done
- Commit / push (awaiting explicit approval).
- Unrelated dirty: `Artifacts/handoffs/release-0.3.3-20260725T2319Z.md` (left alone).
- Makefile `format` now passes `--format` to the pinned SwiftFormat wrapper (was broken).
