# Handoff — Phase 1 progress (Universal Transfer) — 2026-07-23T07:18Z

## Outcome
INCOMPLETE — Phase 1 not finished. Phases 2–5 not started.

## Verified
- `make verify-fast`: OK (104 unit tests) — `Artifacts/validation/latest/unit-tests.xcresult`
- `make test-integration`: OK (18 tests)

## New since prior handoff (20260723T0018Z)

### Crash / relaunch recovery (FR-TRN recovery)
- `JobRepository.requeueInterruptedTransfers(database:)` moves
  `connecting|downloading|verifying|merging|postProcessing` → `queued`,
  clears `terminalReason`, appends event `recovery.requeued`
- `TransferOrchestrator.start` runs recovery before the queue pump
- Unit: `JobRepositoryTests.testRequeueInterruptedTransfers*`
- Integration: `RecoveryRequeueIntegrationTests`

### Safe ZIP post-processing (FR-FS-005 start)
- `Sources/TransferCore/SafeZipExtractor.swift` — Central Directory parse,
  reject `..` / absolute paths / Unix symlinks, bound entry count (10k) and
  uncompressed size (512 MiB); STORED + DEFLATE (zlib raw) only
- Orchestrator: after promote, if filename ends with `.zip` or MIME contains
  `zip`, extract into sibling `\(basename)-extracted/`; failure →
  `failed` / `postProcessingFailed`
- Unit: `SafeZipExtractorTests` (valid, traversal, absolute, symlink, count)

### curl_multi event-loop foundation (FR-TRN-009)
- C helpers in `DMCurlSupport`: `DMCurlEasyDownloadCreate`/`Finish`,
  `DMCurlMultiCreate`/`AddEasy`/`RemoveEasy`/`Perform`/`Wait`/`InfoRead`/`Cleanup`
- `CurlMultiLoop` in TransferCurlBridge; `TransferCore.downloadRangesViaMulti`
- `SegmentedTransfer.downloadHTTP(..., useCurlMulti:)` optional path
  (Dispatch remains default)
- Integration: `CurlMultiLoopIntegrationTests` (2-range multi + segmented multi)

## Still missing for Phase 1 exit
Job↔profile binding UI, cookie jar UX, custom headers E2E, calendar bandwidth
windows, projects/tags/rules UX, full crash/reboot recovery matrix beyond
active-state requeue, ZIP as user-toggleable preference, curl_multi as default
segmented path + progress aggregation, full traceability + perf gates.
Phase 5 remains BLOCKED without Developer ID.

## Next
Prefer curl_multi as production segmented path (with progress), then
job↔profile binding + Settings. Commit only on explicit human authorization.
