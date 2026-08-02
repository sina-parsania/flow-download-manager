# Handoff — release gate: xctest cannot load UnitTests.xctest

**COMPLETE — root-caused and fixed.** Not a build bug, not a test failure, not
DerivedData contention, and not intermittent. macOS withholds removable-volume
access from `xctest` when the release script is started by its shebang from the
external drive, so the runner cannot read the test bundle it was told to run.

**Repo:** `/Volumes/T7 Shield/Projects/flow-download-manager`
**Branch:** `main` @ `72f846d`, clean tree. **Nothing published** — no `v0.4.5`
tag, no GitHub release, no appcast change. Verified with `git tag -l v0.4.5`.

---

## Root cause

`/Volumes/T7 Shield` is a **USB (removable) APFS volume**. To load
`UnitTests.xctest` from it, `xctest` needs TCC's
`kTCCServiceSystemPolicyRemovableVolumes`. Whether the grant is issued depends
on **what the process's executable image is**:

- Started by its **shebang**, a script's executable image is the script file
  itself. When that file is on the removable volume, the grant is withheld from
  the whole process tree → `NSBundle` creation returns nil → reported as
  *"Failed to create a bundle instance representing … Check that the bundle
  exists on disk."* The bundle is fine; the process may not read it.
- Started as **`bash <script>`**, the image is the interpreter on internal
  storage, the script is merely data, and the grant is issued → the same bundle
  on the same USB volume loads.

`Scripts/release/publish.sh` is executable and was run directly, so the release
always took the failing branch. `make verify-fast` by hand is rooted at an
internal binary, so it always passed — that is the whole "same command passes
standalone" mystery.

### Measured evidence

Decisive A/B on **one file** on the USB volume, alternating invocation, with
`DERIVED` on the removable volume throughout:

| Invocation | Executable image | Runs | Result |
| --- | --- | --- | --- |
| `./p.sh` (shebang) | the script, on USB | 3 | **3 RED** |
| `bash ./p.sh` | bash, on internal | 3 | **3 PASS** |

Consistent with every earlier run: shebang-exec from the USB volume 9/9 RED;
shebang-exec from `/private/tmp` and `bash`-exec 12/12 PASS. n=27, no exceptions.

An earlier draft of this handoff attributed the fault to the script's *location*
alone. That was wrong: a script on the removable volume passes when invoked as
`bash <script>`. The executable image, not the file's address, is what decides.

`tccd`, same predicate, per run window:

```text
===== USB-script  -> RED  =====
   3 kTCCServiceSystemPolicyAllFiles        -> Auth Right: Denied
     (no RemovableVolumes grant at all)
===== INTERNAL-script -> PASS =====
   1 kTCCServiceSystemPolicyAllFiles        -> Auth Right: Denied
   1 kTCCServiceSystemPolicyRemovableVolumes -> Auth Right: Allowed
```

The `AllFiles -> Denied` line appears in passing runs too — it is routine for
Xcode and is **not** the signal. `RemovableVolumes -> Allowed` is.

---

## Remedy

**Applied:** `Makefile` now runs the release as `bash Scripts/release/publish.sh`
instead of letting the shebang start it, so the process image is the interpreter
on internal storage. Verified through the real `make` layer, interleaved with a
negative control:

| `make` recipe | Runs | Result |
| --- | --- | --- |
| `@bash Scripts/release/publish.sh` | 2 | **2 PASS** |
| `@Scripts/release/publish.sh` (shebang, control) | 2 | **2 RED** |

**Use `make release VERSION=0.4.5`** (or `bash Scripts/release/publish.sh 0.4.5`).
Running `./Scripts/release/publish.sh` directly still fails — by nature, not by
oversight — but now dies with an explanation instead of the bundle error.

**A fix that was tried and rejected:** having `publish.sh` re-exec itself via
`exec bash "$0" "$@"`. It does **not** work — verified 3/3 still failing. `exec`
preserves the attribution the parent established, so the interpreter has to be
the process image from the start. It is recorded here so nobody re-attempts it.

**Broader, optional and untested:** granting Full Disk Access to the terminal
that runs the release should fix every tool on this volume, not just this
script. Not verified, because it needs a human at System Settings.

Moving `DERIVED` does **not** help — it was on the USB volume throughout all
passing runs.

---

## Gate verification after the fix

All three release lanes, run with the release `DERIVED` on the removable volume,
2026-08-02 20:21–20:22 UTC+3:30:

```text
verify-fast:      PASS   Executed 563 tests, with 0 failures (0 unexpected)
test-integration: PASS   Executed  78 tests, with 0 failures (0 unexpected)
test-recovery:    PASS   Executed  10 tests, with 0 failures (0 unexpected)
```

651 tests, 0 failures, `** TEST EXECUTE SUCCEEDED **` on each lane. Tree clean
afterwards.

**Still not exercised:** publish.sh's own end-to-end path (version bump, DMG,
Sparkle zip, appcast verification). `make release VERSION=0.4.5 DRY_RUN=1`
requires the fix commit to be pushed first — publish.sh refuses to run with
unpushed commits — and that push was deliberately not made here.

---

## Hypotheses refuted by direct measurement

Every one of these was tested, not reasoned about. None reproduce.

| Hypothesis | How it was killed |
| --- | --- |
| xctest read the bundle while it was still being written | Bundle complete at **19:12:48**; first failure **19:12:51** |
| Code-signing still in flight | `codesign` ran **19:12:41–42**, nine seconds before the failure |
| A second process sharing DerivedData (xcodebuildmcp) | xcodebuildmcp (4731, 5410) and the Flow app (29725) were **running during the 12 passing runs** |
| Corrupt bundle / unresolved Sparkle | The exact failed bundle loads: `xcrun xctest` runs the suite, `codesign -v --deep --strict` rc=0 |
| Absolute `DERIVED` / space in the path | 3/3 pass with the absolute space-containing path |
| Cold vs warm tree | Cold wipe + full `verify-fast` passed; the red run at 19:35 was on a **warm** tree |
| Freshly relinked + re-signed bundle | Forced relink+resign before each run: 5/5 pass (executable and `CodeResources` confirmed rewritten) |
| Spotlight bulk-index storm after a 1.5 GB cold build | Wipe + 5 consecutive runs during the indexing window: 5/5 pass |
| `MAKEFLAGS` / jobserver inheritance | Already unset; reproduced with it unset |
| Retrying the lane | Retry fires and fails identically — expected, the condition is deterministic, not transient |

---

## Corrections to the previous handoff

- **"It is intermittent."** It is not. It is deterministic on how the script is
  invoked. The apparent flakiness came from comparing runs launched different
  ways, and from a "passing DRY_RUN" that predates `e9d97aa` (18:37) and
  therefore used a different `DERIVED`.
- **"`7a79181` was reverted."** The Makefile change was. The `run_lane` retry in
  `Scripts/release/publish.sh` was **still live at HEAD**, doubling the cost of
  every failing run. It has now been removed — the condition is deterministic,
  so retrying never helped, exactly as the previous session observed.
- `publish.sh`'s own comments name the jobserver and xcodebuildmcp as causes
  with confidence. Both are refuted above (CLAUDE.md RULE 2).

---

## Separate real defect found

Two of them, same shape: something the gate or the build writes is left
untracked, and `publish.sh`'s own preflight (`working tree is dirty — commit or
stash first`) then refuses to start the **next** release.

1. `default.profraw`, written to the repo root by any coverage-enabled test run.
   Fixed by gitignoring it.
2. `Artifacts/release/sbom.txt` and `Artifacts/release/*.dmg.sha256`, rewritten
   by every build and tracked on purpose, but never added to either release
   commit. Confirmed live: the tree was dirty with exactly these two files
   immediately after v0.4.5 published. Fixed by adding them to the version-bump
   commit.

Everything else a release produces (`*.dmg`, `sparkle/*.zip`, the generated
`.xcodeproj`) is gitignored, and `docs/appcast.xml` plus `sparkle/*.md` are
committed by the appcast step — so the tree is now clean after a release.

---

## Not done

- Fix committed as `cad3de3` on `main`, **not pushed**. `Makefile`,
  `Scripts/release/publish.sh`, `.gitignore`, and this handoff.
- Nothing published; `v0.4.5` is still untagged, no release, no appcast change.
- The full `DRY_RUN` rehearsal was **not** run — it needs `cad3de3` pushed, and
  pushing was not authorized in this slice. The three test lanes were verified
  directly instead (above); the DMG and Sparkle steps remain unexercised.
- The Full Disk Access route is untested (needs a human at System Settings).
- `make lint` was not re-run for these changes; they touch shell and make only,
  no Swift (CLAUDE.md RULE 1 still applies to anyone extending them).
