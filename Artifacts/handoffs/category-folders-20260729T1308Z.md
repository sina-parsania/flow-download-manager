# COMPLETE — category folders (schema v8)

Sorts each download into a folder named for its category inside the download
directory. Off by default. Nothing committed or pushed (RULE 3).

## Evidence

```
make format-check      0/235 files require formatting
make verify-fast       467 tests, 0 failures — incomplete-work-scan: clean — verify-fast: OK
make test-integration   62 tests, 0 failures — ** TEST SUCCEEDED **
make test-recovery       9 tests, 0 failures — ** TEST SUCCEEDED **
```

Unit 455 → 467, integration 59 → 62.

Migration upgrade path: `Tests/Unit/MigrationTests.swift` seeds with `v5Only` and
`v6Only` and then opens with `current`, so an old database migrating through v7
and v8 is exercised — not only fresh v1→v8 creation.

## Design — why the folder is stamped, not computed

The folder is written to the job row **once** (`jobs.categorySubfolder`, schema
v8) and never recomputed. Deriving it per attempt from the live setting and the
live category would move a job's directory between attempts, leaving its
`.partial` and `.segmap` at the old path and re-downloading from zero.
Consequences, all covered by tests:

- Toggling the setting affects **new** downloads only.
- Recategorising a started job does **not** move its bytes.

Stamping happens in `TransferOrchestrator.runJob` immediately **after**
`refineCategoryIfOther` and before the partial path is built. That ordering is
load-bearing: the probe's early identity is what upgrades a job out of `other`,
so a bare link that turns out to be a video lands in `Videos`, not `Other`.
Enqueue-time stamping — the obvious first design — would have put it in `Other`.

`TransferJobDetails.writeDirectory` is now the single source for every path built
for a job. Five sites independently rebuilt the partial/final path from
`destinationDirectory`; all now go through `writeDirectory`. `destinationDirectory`
remains the receiver for `startAccessingSecurityScopedResource` — the scope covers
descendants.

## Failure handling

A plain **file** occupying the folder name fails the job with
`destinationUnavailable` and leaves that file untouched. It deliberately does not
fall back to the parent: a silent fallback would put bytes somewhere the row does
not describe, and a resumed job would look for its partial in the wrong place.

## Two bugs found and fixed during review

Both are the same shape — code that rebuilds a job's location from the
destination profile alone, which knows nothing about `categorySubfolder`.

**1. Crash recovery looked in the wrong folder.**
`FinalizationIntentRepository.recoverInterrupted` resolved the destination from
the profile bookmark, so after a crash it would look for the partial in the
**parent** of a job written into a category folder — find neither partial nor
final file, and fail a job whose bytes were safely one level down. Now takes
`categorySubfolder`. Found only because the end-to-end integration test existed;
every unit test passed against the broken version.

**2. Every state transition rewrote the Location column to the parent.**
`updateJobState` calls `JobLocationTimeline.refreshDestinationPath(&job, profile:)`
on **every** transition, and that resolved the profile alone — so the stamped
path was clobbered on the next state change and the Location column pointed at a
folder the file is not in, which is precisely what 0.3.4's stored path exists to
prevent. `refreshDestinationPath` now appends the subfolder and is the single
implementation of "where does this job's file live"; `stampCategorySubfolder`
calls it rather than duplicating the arithmetic.

Covered by `testStateTransitionKeepsTheSubfolderInTheStoredPath`, which was
mutation-tested: reverting the fix makes it fail.

**Revision handling.** `stampCategorySubfolder` deliberately does **not** bump
`revision`, matching `JobLocationTimeline`'s precedent for agent-internal path
bookkeeping. Bumping it would reject a Pause or Cancel clicked between the last
UI poll and the stamp, with a revision conflict the user cannot see. Covered by
`testStampingDoesNotBumpTheRevision`.

## Files

- `Sources/Persistence/SchemaMigrator.swift` — v8 `categorySubfolder`
- `Sources/Persistence/Records.swift` — `JobRecord.categorySubfolder`
- `Sources/Persistence/JobRepository.swift` — `stampCategorySubfolder`,
  `TransferJobDetails.writeDirectory`
- `Sources/Persistence/FinalizationIntentRepository.swift` — recovery fix
- `Sources/Domain/CategoryFolderName.swift` — pure key → folder mapping
- `Sources/EngineAgent/AgentBoolSettings.swift` — `categoryFoldersEnabled`
- `Sources/EngineAgent/TransferOrchestrator.swift` — `resolveWriteDirectory`
- `Sources/EngineAgent/EngineService.swift` — restart wipe / delete-files paths
- `Sources/Presentation/Settings/SettingsView.swift` — toggle + caption

**No new RPC.** The toggle rides the existing `getBoolSetting`/`setBoolSetting`
pair, so `EngineControlProtocol` is unchanged and `XPCContractDriftTests` needed
no update.

Folder names are derived from the untranslated stable keys (`Videos`,
`Documents`, …) on purpose: localizing them would mean a language change splits a
category across two folders and orphans already-written paths.
`CategoryFolderName` refuses `..`, `.`, `/`, `:`, NUL, leading dots, empty and
over-64-character keys — the value becomes a filesystem path component.

## Screenshot features — status

| Screenshot row | Status |
|---|---|
| Create Category Folders | **Done, this slice** |
| Download Directory | Already shipped (`DestinationFolderCard`) |
| Start Application on System Startup | Already shipped (Launch at Login) |
| Bandwidth Limit per Download | Already shipped (global policy + per-job + per-host) |
| Max Connections per Download | **Not done** — see below |
| Default User-Agent + Reset / use for browser-sent | **Not done** |
| Show Download Completion Dialog | **Not done** |
| Connections "All at Once" vs "One by One" | **Not doing** — see below |

**Not doing the connection ramp toggle.** Flow already range-probes before
opening connections and tiles the ledger finer than `maxConcurrent`, refilling as
connections free (CLAUDE.md: coarse 4.37 s → fine 0.75 s). That switch exists in
other managers because they have no probe. Adding a user-facing toggle over
machinery that already ramps correctly would touch `SegmentedTransfer` /
`CurlMultiLoop` and put the straggler benchmark at risk for no gain.

**Max Connections should land as a ceiling, not a fixed count.**
`preferredConnectionCount: nil` means "derive from file size", and that
derivation is what the tiling benchmarks were tuned against. Forcing 8 on a
500 KB file is worse than the adaptive default. A global maximum that clamps the
derived value keeps the tuning. It needs a non-bool setting, so unlike this slice
it does need a new RPC — and therefore an update to
`XPCContractDriftTests.expectedSelectors`.

**Global User-Agent** needs the "(Be Careful)" warning kept and default-off: the
browser sends its own UA, and overriding it on browser-handoff downloads breaks
session-bound fetches — the same class of problem 0.3.4's Origin forwarding fixed.
Whether it can apply to browser-sent downloads at all depends on
`NativeHostEngineClient`, which was not checked.

## NOT done

- **Nothing committed or pushed.**
- The four screenshot rows marked "Not done" above.
- `make verify` (full evidence bundle); `test-asan` / `test-tsan` not run — no C
  and no shared-state concurrency changed.
- `SchemaVersions.database` still reads `5` while migrations are at v8. It is
  reported in the handshake as `databaseVersion`; left alone rather than changing
  handshake payload as a side effect of this slice.
