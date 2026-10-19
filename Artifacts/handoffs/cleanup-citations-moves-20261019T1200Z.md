# INCOMPLETE — spec-citation cleanup, local payload prune, three clean type moves

UTC: 20261019T1200Z
Branch: `chore/sort-installer-and-cleanup` (local only, not pushed)

## Changes

- Dropped every citation of the gitignored spec pack from comments: 66 in
  `Sources`/`Tests` (commit 57888c5), 15 more in `Scripts`, `Makefile`,
  `Configuration`, `.swiftlint.yml`, `.github/workflows/ci.yml`. ADRs and
  `AGENTS.md` (which labels them "private spec pack") untouched. CLAUDE.md updated.
- Moved three self-contained types to their own files — pure moves, no access
  level changed (deleted lines == added bodies, checked with a sorted diff):
  - `SegmentLedger` → `Sources/TransferCore/SegmentLedger.swift` (+ `import TransferCurlBridge`)
  - `EngineServices`, `EngineServiceListener` → `Sources/EngineAgent/EngineServiceListener.swift`
  - `TransferLimitInput` → `Sources/Presentation/LibraryWindow/TransferLimitInput.swift`
- Local only, gitignored: 28 old release payloads (DMGs/zips 0.1.0–0.4.2, Sparkle
  deltas, `dmg-stage-zip`) moved to Trash, 612 MB. Each was confirmed present as a
  GitHub release asset first; `sparkle-appcast.sh` needs only the current zip.

## Decided against

- Splitting `EngineControlExporter`, `TransferOrchestrator`, `SegmentedTransfer`'s
  enum body or the `AddDownloadsSheet` view into extension files. Cross-file
  extensions need `private` widened (35 `@State`, exporter/actor state), and
  `.swiftlint.yml` records that large hot-path types are deliberate.
- Untracking `Artifacts/handoffs/`: 240 KB total, and `publish.sh` points at one.
- Renaming `App`/`Application`: churn across `project.yml` and imports for no
  behaviour gain.

## Evidence

- `make verify-fast`: `Executed 566 tests, with 0 failures`, `lint: swiftlint (strict) OK`, `verify-fast: OK`
- `make test-integration`: `Executed 78 tests, with 0 failures`
- `make test-recovery`: `Executed 10 tests, with 0 failures` / `Executed 6 tests, with 0 failures`
- `bash -n Scripts/*.sh` OK; `ci.yml` and `.swiftlint.yml` parse as YAML

## Not done

- Live app check of the table-sort slice (installed Flow + engine still running;
  debug build shares bundle id and database).
- `make test-tsan` / `test-asan`: no concurrency, C, or curl-lifetime change.
- Trash not emptied — the 612 MB is reclaimed only when it is.
- Installer provenance (attestation / signed checksum).
- Nothing pushed.
