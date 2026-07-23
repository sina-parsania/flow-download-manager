# Handoff — Phase 1 progress (Universal Transfer) — 2026-07-23T08:33Z

## Outcome
INCOMPLETE — Phase 1 not finished. Phases 2–5 not started.

## Baseline
- HEAD at start of this slice: `305ce3b` (branch `main`; **no commit** this session)

## Verified
- `make verify-fast`: OK (**148** unit tests) — `Artifacts/validation/latest/unit-tests.xcresult`
- `make test-integration`: OK (**20** tests)

## New since prior handoff (20260723T0824Z)

### 1. Dock / URL scheme handoff (FR-ING)
- `CFBundleURLTypes` for local-dev scheme `downloadmanager` via `project.yml` → generated Info.plist
- `OpenURLIngest.parse(_:)` (Application) — query `url=` (repeated) and path-as-URL; never auto-starts
- App `onOpenURL` → `LibraryModel.handleOpenURL` → Add sheet prefill only
- Unit: `OpenURLIngestTests`

### 2. Pause All / Resume All
- Toolbar + menu commands; client-side loop over `listJobs` states + `controlJob`
- `BulkJobCommandFilter` for pause/resume eligibility
- Unit: `BulkJobCommandFilterTests`

### 3. Recovery matrix expansion
- Integration: downloading + partial → `requeueInterruptedTransfers` → orchestrator resume completes (`FaultHTTPServer`)
- Integration: failed (`networkUnavailable`) → retry-equivalent requeue → completes
- `RecoveryMatrixIntegrationTests` (+2)

### 4. Priority / queue reorder
- `JobRepository.setPriority` / `moveQueuePosition`
- XPC `setJobPriority` (+ DTOs, interface, EngineClient, capabilities)
- Inspector Priority Up/Down; `JobSnapshot.priority` / `JobRowModel.priority`
- Unit: `JobRepositoryTests.testSetPriorityAndMoveQueuePositionReorderQueuedJobs`,
  `XPCCodingTests.testSetJobPriorityDTORoundTrip`

## Still missing for Phase 1 exit
Assign project/tags from inspector E2E polish, fuller crash/reboot recovery matrix,
ZIP as user-toggleable preference, curl_multi progress aggregation, full traceability +
perf gates. Phase 5 remains BLOCKED without Developer ID.

## Next
Phase 1 exit gates (remaining recovery cases, ZIP preference, progress aggregation, perf).
Commit only on explicit human authorization.
