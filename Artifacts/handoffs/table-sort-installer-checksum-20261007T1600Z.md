# INCOMPLETE — table sort behaves like Finder + installer fails closed on missing checksum

UTC: 20261007T1600Z

## Changes

- `JobTableSorting`: rows that render "—" for the sorted column (speed 0, ETA 0/nil,
  unknown size, no date, no location) sort last in **both** directions. Before, the
  descending flip put every blank row at the top.
- `JobTableSortKey.defaultAscending`: first header click is descending for Size,
  Speed, Progress, Started, Finished (Finder convention); ascending for the rest.
- Status sorts by lifecycle rank (downloading → … → completed), not alphabetically.
- `JobTableView`: last sort key/direction persisted in `UserDefaults`
  (`JobTable.sortKey`, `JobTable.sortAscending`) and restored on launch; column
  order/width autosaved (`autosaveName = "FlowJobTable"`).
- `JobTableView.syncSelection`: scrolls to the selected row only when it changes.
  It ran on every 500 ms poll, so under a Speed/ETA sort the list snapped back to
  the moving selected row and could not be browsed.
- `Scripts/install.sh`: dies when the release has no `.sha256` asset (every release
  v0.1.0…v0.4.5 publishes one, checked with `gh release view`), validates the hash
  format, and only then downloads the DMG.

## Evidence

- `xcodebuild … -only-testing:UnitTests/JobTableSortingTests test`: 8 tests, 0 failures
- `make verify-fast` (after final change): `Executed 566 tests, with 0 failures`,
  `lint: swiftlint (strict) OK`, `verify-fast: OK`
- `bash -n Scripts/install.sh`: OK; v0.4.5 `.sha256` matches `^[0-9a-f]{64}$`

## Not done

- **Live app check not run.** The installed Flow and its engine were running; the
  debug build shares the bundle id and database, so a second engine was not
  started. Still to confirm by hand: sort indicator restored after relaunch,
  columns restored, no scroll snap while a download runs.
- No new unit test for the scroll-snap fix (AppKit coordinator, not in the pure layer).
- Installer still trusts a checksum from the same origin as the DMG — catches
  corruption, not a compromised release. Real fix: `gh attestation verify` or a
  signed checksum.
- Integration/recovery/sanitizer lanes not run — no transfer, persistence, XPC or
  C code changed.
