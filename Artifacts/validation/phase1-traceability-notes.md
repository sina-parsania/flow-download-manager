# Phase 1 traceability notes (FR → test coverage)

Private prompt-pack `10-traceability-matrix.md` is not in this repository.
This artifact maps Phase 1 functional / non-functional requirement IDs to
first-party automated tests as of 2026-07-23 (Universal Transfer automated scope).

Schema / XPC: database schema v3; agent bool setting `zipAutoExtractEnabled`
(default true).

| FR ID | Area | Tests |
| --- | --- | --- |
| FR-ING | URL paste / extract / dedupe | `URLTextExtractorTests` (`testExtractDedupesAndOrders`, related), `ConfirmationGateTests` |
| FR-ING | Add sheet enqueue (batch) | `JobRepositoryTests.testEnsureProductionSeedInsertBatchAndFetchQueuedRows`, `XPCCodingTests.testEnqueueBatchRequestOptionalFieldsRoundTrip`, Orchestrator path via `OrchestratorIntegrationTests.testQueuedJobDownloadsFromFaultServer` |
| FR-ING | Clipboard opt-in monitoring | `ClipboardMonitoringDecisionTests` (all four cases) |
| FR-ING | Dock / URL scheme handoff | `OpenURLIngestTests` (`testParseQueryURL`, `testParsePathAsHTTPURL`, `testIgnoresForeignSchemesAndEmptyPayloads`) |
| FR-ING | Finder / window drop + text import | `ImportTextIngestTests` (`testIsImportableAcceptsTxtCsvAndExtensionless`, `testReadTextDecodesUTF8AndRejectsOversized`) |
| FR-TRN-001/002 | Single-stream HTTP(S) transfer + promote | `TransferCoreIntegrationTests.testSingleStreamDownloadAndPromote`, `TransferFinalizerTests.testPromoteMovesPartialToFinal` |
| FR-TRN-003/004 | Credential / proxy profiles | `ProfileAndScheduleTests` (`testCredentialProfileRoundTripUserpwd`, `testProxyProfileURL`, `testListCredentialAndProxyProfiles`), `XPCCodingTests` profile DTOs |
| FR-TRN-005 | Custom headers validation | `RetryAndHeaderTests` (`testRejectsBannedAndCRLF`, `testParseExtraHeadersRejectsInvalidEntry`, `testParseHeaderLinesAndEncode`) |
| FR-TRN-006 | Cookie jar profile (path only) | `ProfileAndScheduleTests.testCookieProfileJarPathUnderApplicationSupport`, `XPCCodingTests.testCookieAndBandwidthDTORoundTrip` |
| FR-TRN-007 | Resume / Range | `ResumeTransferIntegrationTests.testResumeContinuesPartialFile`, `TransferCoreIntegrationTests.testRangeProbeReturns206`, `FaultServiceIntegrationTests.testRangeRequestReturns206WithContentRange` |
| FR-TRN-008 | Abort / cancel mid-transfer | `ResumeTransferIntegrationTests.testAbortDuringDownloadThrows`, `SegmentPolicyAndIntegrityTests.testAbortFlagStopsTransfer` |
| FR-TRN-009 | Segmented / curl_multi | `SegmentedTransferIntegrationTests.testTwoSegmentDownloadMatchesFixture`, `CurlMultiLoopIntegrationTests` (`testTwoRangeDownloadsViaMultiMatchFixture` incl. aggregated progress, `testSegmentedTransferOptionalCurlMultiPath`), `SegmentPolicyAndIntegrityTests` (`testPreferredSegmentCountScalesWithSize`, `testPreferredSegmentCountHonorsHostMaxHint`), `CurlBridgeTests` |
| FR-TRN-010 | Retry policy | `RetryAndHeaderTests` (`testRetriesTransientStatusesOnly`, `testRetryAfterHonored`), `RecoveryMatrixIntegrationTests.testFailedRetryableRetryCommandCompletes` |
| FR-TRN-011 | Bandwidth governor | `TransferBudgetTests.testSyncBandwidthGovernorCapsThroughput` (+ related budget tests) |
| FR-TRN recovery | Crash / relaunch requeue | `JobRepositoryTests.testRequeueInterruptedTransfersMovesDownloadingToQueued`, `RecoveryRequeueIntegrationTests.testRequeueInterruptedDownloadingJob`, `RecoveryMatrixIntegrationTests.testDownloadingPartialRequeueThenResumeCompletes` |
| FR-TRN restart | Restart-from-scratch | `RestartFromScratchIntegrationTests.testStartPauseRestartWipesPartialAndCompletesFullFile`, `JobRepositoryTests.testClearResourceIdentitySizeClearsExpectedSizeAndValidators`, `XPCCodingTests.testJobCommandRestartRoundTrip` |
| FR-FS-004 | Atomic promote | `TransferFinalizerTests`, `TransferCoreIntegrationTests.testSingleStreamDownloadAndPromote` |
| FR-FS-005 | Safe ZIP post-process | `SafeZipExtractorTests` (valid / traversal / absolute / symlink / count), `AgentBoolSettingsTests` (`testZipAutoExtractDefaultsTrueWhenUnset`, `testZipAutoExtractRoundTripFalse`, `testUnknownKeyRejected`), `XPCCodingTests.testSetJobProjectAndBoolSettingRoundTrip` |
| FR-FS-006 | Finder reveal / destination conflict | `DestinationConflictPolicyTests` (all three) |
| FR-QUE | One-shot schedule promote | `ProfileAndScheduleTests.testOneShotSchedulePromotion` |
| FR-QUE | Calendar bandwidth windows | `BandwidthWindowEvaluatorTests` (empty/daily/weekday/wrap/parse), `ProfileAndScheduleTests.testGlobalBandwidthPolicyRoundTrip`, `MigrationTests.testV2ToV3MigrationAddsBandwidthPolicies` |
| FR-QUE | Queue priority / bulk pause-resume filters | `JobRepositoryTests.testSetPriorityAndMoveQueuePositionReorderQueuedJobs`, `BulkJobCommandFilterTests` |
| FR-CAT | Classification / built-in maps | `ClassificationEngineTests` (all eight) |
| FR-CAT | User category rules | `CategoryRulesEngineTests` (all five) |
| FR-CAT | Low-confidence confirmation gate | `ConfirmationGateTests` (all five) |
| FR-ORG | Projects / tags persistence | `OrganizationRepositoryTests` (`testCreateProjectTagAttachAndList`, `testUpsertTagNameFoldUniqueness`), `JobRepositoryTests.testInsertBatchPersistsProfilesProjectAndSchedule` |
| FR-ORG | Assign project/tags (XPC DTOs) | `XPCCodingTests.testSetJobProjectAndBoolSettingRoundTrip` (SetJobProject + JobSnapshot IDs); UI wired in `InspectorView` (manual VoiceOver lane) |
| FR-UX | Job events inspector | `JobRepositoryTests.testAppendAndListEventsFiltersByJobAndLimit`, `XPCCodingTests.testEventSnapshotRoundTrip` |
| FR-UX | Delete / clear failed guards | `DeleteJobGuardTests`, `JobRepositoryTests.testDeleteTerminalJobRejectsNonTerminalAndRemovesTerminalRow` |
| FR-UX-002/004 | Menu bar / notifications foundation | covered by Presentation wiring; automated smoke via app launch UI tests |
| NFR-REL-001/002 | Exhaustive state machines | `JobStateTransitionTests`, `SegmentStateTransitionTests`, `DomainValueTests` |
| NFR-REL-004 | Migrations / integrity / backup | `MigrationTests`, `DatabaseIntegrityTests`, `BackupRestoreTests` |
| NFR-SEC-001 | Keychain / redaction | `SharedSecurityTests`, `ObservabilityTests` |
| NFR-SEC-002/003 | Authenticated versioned XPC | `XPCRoundTripTests`, `XPCCodingTests` |
| NFR-PERF (lite) | Batch smoke (not full 10k gate) | `BatchPerformanceSmokeTests` |
| NFR-A11Y | Labels / shortcuts foundation | `AppLaunchUITests`; full VoiceOver = manual (see accessibility-report) |
| Phase 2 stubs (out of Phase 1 exit) | Torrent / media isolation present as modules | `TorrentBencodeTests`, `MediaIsolationTests` (not Phase 1 exit criteria) |

## Explicitly outside automated Phase 1 claim

- Interactive VoiceOver / full accessibility lane (manual)
- Developer ID signing + notarization (Phase 5)
- Full NFR-PERF 10k transfer gate beyond smoke
- Chrome extension / remote ingest (later phases)

## Settings / agent preference keys

| Key | Default | Storage | Tests |
| --- | --- | --- | --- |
| `zipAutoExtractEnabled` | `true` | Agent `UserDefaults` via XPC get/set bool | `AgentBoolSettingsTests`, `XPCCodingTests.testSetJobProjectAndBoolSettingRoundTrip` |
| `clipboardMonitoringEnabled` | `false` | App `UserDefaults` | `ClipboardMonitoringDecisionTests` |
