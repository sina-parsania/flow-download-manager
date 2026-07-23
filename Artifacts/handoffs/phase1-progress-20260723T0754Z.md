# Handoff — Phase 1 progress (Universal Transfer) — 2026-07-23T07:54Z

## Outcome
INCOMPLETE — Phase 1 not finished. Phases 2–5 not started.

## Verified
- `make verify-fast`: OK (108 unit tests) — `Artifacts/validation/latest/unit-tests.xcresult`
- `make test-integration`: OK (18 tests)

## New since prior handoff (20260723T0718Z)

### A. curl_multi default for segmented transfers
- `SegmentedTransfer.downloadHTTP` defaults `useCurlMulti: true`
- Recoverable multi setup failure (`TransferError.fileOpenFailed`) falls back once to Dispatch
- Integration: `CurlMultiLoopIntegrationTests`, `SegmentedTransferIntegrationTests` green

### B. Custom headers on download (FR-TRN-005)
- `DownloadOptions.extraHeaders` + `extraHeadersCurlPayload`
- CCurl: `extraHeaders` newline payload → `curl_slist` / `CURLOPT_HTTPHEADER` on easy + multi create
- `HeaderValidator.parseExtraHeadersJSON` — any invalid entry rejects the whole set
- Orchestrator applies validated headers; `ParseError` → job `failed` / `dependencyProtocolMismatch`
- Unit: `HeaderValidatorTests.testParseExtraHeadersRejectsInvalidEntry`

### C. Projects & tags (FR-ORG minimal)
- `OrganizationRepository`: create/upsert project & tag, attach/set job tags, list, setJobProject
- XPC: `listOrganization` / `upsertProject` / `upsertTag` / `setJobTags` + DTOs
- `JobSnapshot` + `listJobs` join include `projectName` / `tagNames`
- Settings: Projects & Tags section; Library inspector already surfaces them
- Unit: `OrganizationRepositoryTests` (2)

### D. Sync bandwidth governor (FR-TRN-011)
- `SyncBandwidthGovernor` (NSLock + `Thread.sleep`, `systemUptime` refill)
- Wired via `DownloadOptions.maxBytesPerSecond` on the progress path
- Unit: `TransferBudgetTests.testSyncBandwidthGovernorCapsThroughput`

## Still missing for Phase 1 exit
Job↔profile binding UI, cookie jar UX, custom headers UI/E2E enqueue path,
calendar bandwidth windows, rules UX, full crash/reboot recovery matrix,
ZIP as user-toggleable preference, curl_multi progress aggregation,
full traceability + perf gates. Phase 5 remains BLOCKED without Developer ID.

## Next
Wire maxBytesPerSecond from job/settings, custom-headers UI on Add Downloads,
assign project from inspector, then Phase 1 exit gates.
Commit only on explicit human authorization.
