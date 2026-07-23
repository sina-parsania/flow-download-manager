# Phase 1 traceability notes (FR coverage stub)

Private prompt-pack `10-traceability-matrix.md` is not in this repository.
This artifact lists Phase 1 FR IDs covered by first-party tests as of
2026-07-23 (schema v3 / bandwidth windows slice).

| FR ID | Area | Tests |
| --- | --- | --- |
| FR-ING | URL paste / Add sheet enqueue | `URLTextExtractorTests`, Add sheet wiring via `EngineClient.enqueueBatch` |
| FR-ING | Clipboard opt-in monitoring | `ClipboardMonitoringDecisionTests` |
| FR-TRN-003/004 | Credential / proxy profiles | `ProfileAndScheduleTests`, `XPCCodingTests` |
| FR-TRN-005 | Custom headers validation | `HeaderValidatorTests` (`testRejectsBannedAndCRLF`, `testParseExtraHeadersRejectsInvalidEntry`, `testParseHeaderLinesAndEncode`) |
| FR-TRN-011 | Bandwidth governor | `TransferBudgetTests.testSyncBandwidthGovernorCapsThroughput` |
| FR-QUE | One-shot schedule promote | `ProfileAndScheduleTests.testOneShotSchedulePromotion` |
| FR-QUE | Calendar bandwidth windows | `BandwidthWindowEvaluatorTests` (empty/daily/weekday/wrap/parse), `ProfileAndScheduleTests.testGlobalBandwidthPolicyRoundTrip`, `MigrationTests.testV2ToV3MigrationAddsBandwidthPolicies` |
| FR-CAT | Classification / rules | `ClassificationEngineTests`, `CategoryRulesEngineTests` |
| FR-ORG | Projects / tags | `OrganizationRepositoryTests`, Settings XPC DTOs |
| FR-UX | Job events inspector | `JobRepositoryTests.testAppendAndListEventsFiltersByJobAndLimit`, `XPCCodingTests.testEventSnapshotRoundTrip` |
| NFR-REL | Schema migrations | `MigrationTests` (v1→v2, v2→v3, interrupted rollback) |
| Cookie jars | Profile path + empty jar | `ProfileAndScheduleTests.testCookieProfileJarPathUnderApplicationSupport`, `XPCCodingTests.testCookieAndBandwidthDTORoundTrip` |

Still incomplete for Phase 1 exit: full crash/reboot recovery matrix, ZIP preference toggle,
curl_multi progress aggregation, full perf gates, Developer ID (Phase 5).
