# Handoff — Phase 1 progress (Universal Transfer) — 2026-07-23T08:24Z

## Outcome
INCOMPLETE — Phase 1 not finished. Phases 2–5 not started.

## Baseline
- HEAD at start of this slice: `7ace955` (branch `main`; **no commit** this session)

## Verified
- `make verify-fast`: OK (**140** unit tests) — `Artifacts/validation/latest/unit-tests.xcresult`
- `make test-integration`: OK (**18** tests)

## New since prior handoff (20260723T0815Z)

### 1. Calendar bandwidth windows (FR-QUE)
- Schema **v3** (`v3-bandwidth-policies`): `bandwidth_policies(id, name, windowsJSON, maxBytesPerSecond)`
- `BandwidthWindowEvaluator` (Application) — `isActive(now:calendar:windows:)`, parse/encode JSON windows
- Global policy id `ProfileRepository.globalBandwidthPolicyID`; orchestrator pump skips starting jobs outside windows; inside window applies `maxBytesPerSecond`
- Settings → Bandwidth: max B/s + “Only between 00:00 and 08:00 daily” preset
- XPC: `upsertBandwidthPolicy` / `getBandwidthPolicy`
- Unit: `BandwidthWindowEvaluatorTests`, `MigrationTests.testV2ToV3MigrationAddsBandwidthPolicies`,
  `ProfileAndScheduleTests.testGlobalBandwidthPolicyRoundTrip`

### 2. Custom headers UI (Add sheet)
- Multiline `Header-Name: value` editor; `HeaderValidator.parseHeaderLines` + `encodeExtraHeadersJSON`
- Invalid lines show inline error; enqueue blocked until fixed
- Engine validates `customHeadersJSON` on enqueue
- Unit: `HeaderValidatorTests.testParseHeaderLinesAndEncode`

### 3. Cookie profile UX
- Settings → Cookies: list + create (display name → `cookie_profiles` + empty jar under Application Support)
- Add sheet Cookie profile picker wired to `listProfiles.cookies` / enqueue `cookieProfileID`
- XPC: `upsertCookieProfile`; `ListProfilesResponse.cookies`
- Unit: jar file emptiness asserted; `XPCCodingTests.testCookieAndBandwidthDTORoundTrip`

### 4. Traceability stub
- Private pack matrix not in repo → `Artifacts/validation/phase1-traceability-notes.md`

## Still missing for Phase 1 exit
Assign project/tags from inspector E2E polish, full crash/reboot recovery matrix,
ZIP as user-toggleable preference, curl_multi progress aggregation, full traceability +
perf gates. Phase 5 remains BLOCKED without Developer ID.

## Next
Phase 1 exit gates (recovery matrix, ZIP preference, progress aggregation, perf).
Commit only on explicit human authorization.
