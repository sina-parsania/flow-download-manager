# Handoff — Phase 1 progress (Universal Transfer) — 2026-07-23T08:05Z

## Outcome
INCOMPLETE — Phase 1 not finished. Phases 2–5 not started.

## Verified
- `make verify-fast`: OK (118 unit tests) — `Artifacts/validation/latest/unit-tests.xcresult`
- `make test-integration`: OK (18 tests)

## New since prior handoff (20260723T0754Z)

### A. Job↔profile binding in Add sheet
- `EnqueueBatchRequest` batch-level optional fields: `credentialProfileID`,
  `proxyProfileID`, `cookieProfileID`, `customHeadersJSON`, `projectID`,
  `scheduleStartAtISO8601` (nil-compatible decode; XPC protocol version unchanged)
- `JobRepository.insertBatch` persists bindings; with `scheduleStartAt` creates
  one-shot schedule and jobs in `scheduled` (not `queued`)
- `AddDownloadsSheet`: credential/proxy/project pickers + optional Start-at
  `DatePicker`; `EngineClient.enqueueBatch` signature updated
- Unit: `JobRepositoryTests.testInsertBatchPersistsProfilesProjectAndSchedule`,
  `XPCCodingTests` optional-field round-trip + nil compatibility

### B. Category rules engine (FR-CAT minimal)
- `CategoryRulesEngine` — ordered rules; predicates
  `{"extension":"mp4"}` / `{"mimePrefix":"video/"}` → category stableKey
- `ClassificationEngine.classify(..., rules:)` — rule match overrides built-ins
- `CategoryRulesRepository` CRUD; no seeded user rules
- XPC: `listCategoryRules` / `upsertCategoryRule` + DTOs
- Settings: Category Rules section (extension → category)
- Add sheet loads rules via XPC and passes them into classify
- Unit: `CategoryRulesEngineTests` (precedence, priority, MIME, repository)

### C. Process sleep assertion during active transfer
- `SleepAssertionHolding` + `NoOpSleepAssertionHolder` /
  `ProcessInfoSleepAssertionHolder` (`.idleSystemSleepDisabled`)
- `TransferOrchestrator` injects holder; begins on `downloading`, ends when
  job leaves the active transfer run (`defer`)
- Unit: `SleepAssertionHolderTests`

## Still missing for Phase 1 exit
Cookie jar UX, custom-headers UI on Add sheet, calendar bandwidth windows,
assign project/tags from inspector E2E polish, full crash/reboot recovery
matrix, ZIP as user-toggleable preference, curl_multi progress aggregation,
full traceability + perf gates. Phase 5 remains BLOCKED without Developer ID.

## Next
Wire custom-headers UI + cookie profile picker on Add Downloads, then Phase 1
exit gates. Commit only on explicit human authorization.
