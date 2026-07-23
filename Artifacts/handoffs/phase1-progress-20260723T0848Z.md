# Handoff — Phase 1 progress (Universal Transfer) — 2026-07-23T08:48Z

## Outcome
INCOMPLETE — Phase 1 not finished. Phases 2–5 not started.

## Baseline
- HEAD at start of this slice: `fcbac1a` (branch `main`; **no commit** this session)

## Verified
- `make verify-fast`: OK (**163** unit tests) — `Artifacts/validation/latest/unit-tests.xcresult`
- `make test-integration`: OK (**21** tests)

## New since prior handoff (20260723T0840Z)

### 1. Dock / Finder drop + window drop (FR-ING)
- `ImportTextIngest` — txt/csv/extensionless file read (8 MB cap); never auto-starts
- `CFBundleDocumentTypes` for plain-text / CSV (Finder/Dock open onto app icon)
- App `onOpenURL` routes `file://` → `ImportTextIngest` → Add sheet; custom scheme still via `OpenURLIngest`
- `RootView.onDrop` for file URLs + plain text → Add sheet (same path as clipboard)
- Add sheet import path reused `ImportTextIngest`
- Unit: `ImportTextIngestTests`; `OpenURLIngestTests` ignores file URLs

### 2. Batch performance smoke (NFR-PERF lite)
- `BatchPerformanceSmokeTests` — clearly named smoke only (not full NFR gate)
- `URLTextExtractor.extract` on 5000 synthetic http URLs &lt; 2s (`ContinuousClock` + `XCTAssertLessThan`)
- `ClassificationEngine.classify` 5000 times &lt; 1s

### 3. Restart-from-scratch
- `JobCommandKind.restart = 5` — wipe `.partial`, `clearResourceIdentitySize`, clear progress, queue
- XPC agent `controlJob(.restart)`; UI Retry (keep partial) vs Restart (wipe) on toolbar + inspector
- Integration: `RestartFromScratchIntegrationTests` start → pause → corrupt partial → restart → full fixture completes
- Unit: `JobRepositoryTests.testClearResourceIdentitySize…`, `XPCCodingTests.testJobCommandRestartRoundTrip`

### 4. Menu bar Pause All / Resume All
- `MenuBarController` menu items call `LibraryModel.pauseAll` / `resumeAll`

## Still missing for Phase 1 exit
Assign project/tags from inspector E2E polish, fuller crash/reboot recovery matrix,
ZIP as user-toggleable preference, curl_multi progress aggregation, full traceability +
perf gates (beyond smoke), interactive VoiceOver/accessibility lane. Phase 5 remains
BLOCKED without Developer ID.

## Next
Phase 1 exit gates (remaining recovery cases, ZIP preference, progress aggregation, full perf).
Commit only on explicit human authorization.
