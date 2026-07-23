# Handoff — Phase 1 progress (Universal Transfer) — 2026-07-23T08:15Z

## Outcome
INCOMPLETE — Phase 1 not finished. Phases 2–5 not started.

## Baseline
- HEAD at start of this slice: `915f128` (branch `main`, ahead of origin by 5; **no commit** this session)

## Verified
- `make verify-fast`: OK (**128** unit tests) — `Artifacts/validation/latest/unit-tests.xcresult`
- `make test-integration`: OK (**18** tests)

## New since prior handoff (20260723T0805Z)

### 1. Opt-in clipboard monitoring (FR-ING)
- `ClipboardMonitoringDecision` (Application) — pure helper: notify only when pasteboard
  text changes **and** `URLTextExtractor.validCount > 0`
- `ClipboardMonitor` (Presentation) — polls `NSPasteboard.changeCount` on a timer **only**
  when UserDefaults `clipboardMonitoringEnabled` is true (default false)
- Settings toggle “Monitor clipboard for links”; on detect: user notification
  “Links detected”, set `LibraryModel.pendingClipboardText`, present Add sheet prefilled —
  **never** auto-enqueue
- Unit: `ClipboardMonitoringDecisionTests`

### 2. History / events filter (FR-UX)
- XPC: `listEvents(ListEventsRequest)` → `ListEventsResponse` / `EventSnapshot`
  (sequence, jobID, occurredAtISO8601, type, sanitizedPayload)
- `JobRepository.listEvents(jobID optional, limit)` newest-first
- `EngineService` + `EngineClient.listEvents`
- `InspectorView` Events section for the selected job
- Unit: `JobRepositoryTests.testAppendAndListEventsFiltersByJobAndLimit`,
  `XPCCodingTests.testEventSnapshotRoundTrip`

### 3. FTP/SFTP capability smoke
- Unit: `CurlBridgeTests` asserts `ftp` / `ftps` / `sftp` `isPhase1Supported`;
  `file` / `gopher` / `dict` rejected (no network FTP server; FaultHTTPServer remains HTTP-only)

### 4. Destination conflict policies
- `DestinationConflictPolicy` / `DestinationConflictResolver` (Application)
- `TransferJobDetails.conflictPolicy` loaded from destination profile
- `TransferOrchestrator` applies uniquify / overwrite / fail (`terminalReason:
  destinationExists`) before transfer
- Unit: `DestinationConflictPolicyTests`

## Still missing for Phase 1 exit
Cookie jar UX, custom-headers UI on Add sheet, calendar bandwidth windows,
assign project/tags from inspector E2E polish, full crash/reboot recovery
matrix, ZIP as user-toggleable preference, curl_multi progress aggregation,
full traceability + perf gates. Phase 5 remains BLOCKED without Developer ID.

## Next
Wire custom-headers UI + cookie profile picker on Add Downloads, then Phase 1
exit gates. Commit only on explicit human authorization.
