# COMPLETE — v0.4.0 local release artifacts

Version bumped, all lanes green, DMG built and **verified by installing and
running it**. Committed on `feat/rnd-slices`.

**Not pushed. No GitHub Release. No Sparkle appcast.** Local artifacts only, as
scoped.

## Artifacts

```
Artifacts/release/DownloadManager-0.4.0-unsigned.dmg          26M
Artifacts/release/DownloadManager-0.4.0-unsigned.dmg.sha256   verified OK
Artifacts/release/sbom.txt                                    regenerated
```

## Gate

```
make verify-fast       527 tests, 0 failures — incomplete-work-scan: clean
make test-integration   62 tests, 0 failures
make test-recovery       9 tests, 0 failures
make test-tsan          Unit+Integration+Recovery — 0 data races
make test-performance    6 tests — straggler coarse=4.360s fine=0.741s speedup=5.888x
Release build            ** BUILD SUCCEEDED ** (warnings-as-errors)
```

Unit tests 440 → 527 over this work. The straggler benchmark reads 5.888×
against the documented 5.83× baseline.

## Artifact verification — the part that mattered

Verified on the **shipped DMG**, not the build directory:

1. Mounted the DMG → app reports **0.4.0 (9)**, `DownloadEngineAgent.xpc`
   bundled, ad-hoc signature with no Team ID (expected, ADR 0008).
2. `ditto`'d to a clean location, cleared quarantine, launched it.
3. The installed app brought up the engine agent and established XPC peer
   connections. The full app↔engine chain works from the artifact a user gets.

Also confirmed on a real 168-job database that had been through v1→v7: the
**v8 migration applied cleanly**, and all 168 existing jobs kept
`categorySubfolder` NULL — the feature is correctly off for downloads that
predate it. That is the migration upgrade path proven on live data rather than
a fresh test database.

## A release-blocking bug found by doing this

**The first 0.4.0 DMG shipped an app reporting 0.3.5 build 8.** The file was
named 0.4.0. `make release-dmg-unsigned` reported success, every test passed,
and the only visible symptom would have been a user opening About.

Two causes:

1. `project.yml`'s `info.properties` hardcoded `CFBundleShortVersionString` and
   `CFBundleVersion`. XcodeGen *generates* the plist from that block, so those
   literals silently won over the `MARKETING_VERSION` /
   `CURRENT_PROJECT_VERSION` the build script passes to `xcodebuild`.
2. `build-dmg.sh` derived the build number by reading `CFBundleVersion` back out
   of that same plist — feeding the stale value into the build it was meant to
   be setting.

Both fixed, plus a gate: the script now reads the produced app's Info.plist and
refuses to package on a mismatch, printing requested vs built. It caught the
mismatch on the first rebuild before the `project.yml` fix landed, and now
prints `verified app reports 0.4.0 (9)`.

This is why the release step was "install and run it", not "the build
succeeded".

## What 0.4.0 contains

Fixes — all three are things that claimed to work and did not:

- Global and per-host speed limits were enforced **per transfer**; concurrent
  downloads each ran at the full rate, up to 5× the configured number.
- The yt-dlp helper was resolved relative to the working directory, which is `/`
  for a launched app, so **no released build could ever find it** and the whole
  media chain was unreachable.
- HLS/DASH manifests were treated as downloadable files, producing a few
  kilobytes of playlist text named like a video.

Features: category folders (schema v8) · media page → direct link resolution ·
Firefox companion · filter and search by project or tag · Quick Look ·
`img[001-010].jpg` range expansion.

Internal: XPC contract-drift test · idempotency receipts that a new handler
cannot forget.

## NOT done

- **Not pushed.** 15 commits sit on local `feat/rnd-slices`.
- **No GitHub Release**, no tag, no Sparkle appcast — publishing an appcast
  would offer this to existing users, which is a separate decision.
- **Not notarized / not Developer ID signed** — ad-hoc by design (ADR 0008).
- **Compose enqueue not exercised interactively.** The `downloadmanager://`
  handoff deliberately prefills the Compose sheet rather than auto-queueing
  (links from any process are untrusted), and clicking it needs accessibility
  permission this session does not have. The engine's transfer path is covered
  by the integration and recovery lanes instead.
- Remaining plan slices: max concurrent downloads, renew stale URL, per-job
  limit setter, duplicate detection, shutdown-on-drain, proxy auth, named
  queues, recurring scheduling, full HLS/DASH.
