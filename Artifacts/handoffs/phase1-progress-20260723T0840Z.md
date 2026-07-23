# Handoff — Phase 1 progress (Universal Transfer) — 2026-07-23T08:40Z

## Outcome
INCOMPLETE — Phase 1 not finished. Phases 2–5 not started.

## Baseline
- HEAD at start of this slice: `b33b02f` (branch `main`; **no commit** this session)

## Verified
- `make verify-fast`: OK (**157** unit tests) — `Artifacts/validation/latest/unit-tests.xcresult`
- `make test-integration`: OK (**20** tests)

## New since prior handoff (20260723T0833Z)

### 1. Confirmation UX (FR-CAT)
- `ConfirmationGate.shouldConfirm(results:)` — true if any result has confidence `.low` or category `other`
- Add sheet phases: `none` → `needsConfirmation` (category count summary) → `confirmed` via **Queue anyway**
- Confident non-`other` batches still enqueue on first **Queue Selected**
- Unit: `ConfirmationGateTests`

### 2. Remove completed / Clear Failed
- XPC `deleteJob` (DTOs + interface + capability); agent rejects non-terminal with `invalidPayload`
- `JobRepository.deleteTerminalJob` — DB row (+ owned resource); **never** deletes completed destination files
- Optional `.partial` cleanup for failed/cancelled only (agent-side before delete)
- Toolbar: Remove (selected terminal) + Clear Failed; `DeleteJobGuard` pure guards
- Unit: `DeleteJobGuardTests`, `JobRepositoryTests.testDeleteTerminalJobRejectsNonTerminalAndRemovesTerminalRow`,
  `XPCCodingTests.testDeleteJobDTORoundTrip`

### 3. Accessibility
- `accessibilityLabel` on Pause All / Resume All, Priority Up/Down, Remove / Clear Failed,
  Settings clipboard + bandwidth toggles, Add sheet Start at / queue actions

## Still missing for Phase 1 exit
Assign project/tags from inspector E2E polish, fuller crash/reboot recovery matrix,
ZIP as user-toggleable preference, curl_multi progress aggregation, full traceability +
perf gates, interactive VoiceOver/accessibility lane. Phase 5 remains BLOCKED without
Developer ID.

## Next
Phase 1 exit gates (remaining recovery cases, ZIP preference, progress aggregation, perf).
Commit only on explicit human authorization.
