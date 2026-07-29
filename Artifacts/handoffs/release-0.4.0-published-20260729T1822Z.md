# COMPLETE — v0.4.0 pushed, tagged and published

Branch pushed, merged to `main`, tagged `v0.4.0`, GitHub Release created with
both artifacts. **The Sparkle appcast was deliberately NOT updated** — see below.

## What was published

```
branch   feat/rnd-slices -> origin (16 commits)
main     b5399e3..47bb058 (merge commit, --no-ff)
tag      v0.4.0
release  https://github.com/sina-parsania/flow-download-manager/releases/tag/v0.4.0
         Latest · draft=false · prerelease=false
assets   DownloadManager-0.4.0-unsigned.dmg          27,714,397 bytes
         DownloadManager-0.4.0-unsigned.dmg.sha256          101 bytes
```

## Verification performed on the published artifact

Not on the build directory — on what a user actually receives:

1. `gh release download v0.4.0` into a clean directory → **checksum verifies OK**.
2. Mounted that downloaded DMG → app reports **0.4.0 (9)**.
3. `api.github.com/.../releases/latest` resolves to **v0.4.0** with both assets,
   so the one-line `install.sh` in the README picks it up.

Earlier in the session, before publishing: the merged tree was gated
(verify-fast 527, integration 62, recovery 9, tsan 0 races, performance
straggler 5.888× vs the 5.83× baseline), and the DMG was installed to a clean
location and launched — the app brought up the engine agent and established XPC
peer connections.

The merge commit itself was re-gated before pushing to `main`, since a merge
produces a tree nothing had tested.

## NOT done — and this one matters

**The Sparkle appcast still advertises 0.3.5 (build 8).** Existing users will
NOT be offered 0.4.0 through Check for Updates until `docs/appcast.xml` is
regenerated.

I did not do it, for two reasons:

1. **It needs the EdDSA private key**, which lives in the maintainer's Keychain
   by design. `generate_appcast` is not installed on this machine either.
2. **It is a separate decision.** Publishing the appcast pushes this release at
   every existing install; publishing a GitHub Release only offers it to people
   who go looking. Given 0.4.0 carries a one-way schema migration, that ordering
   is worth keeping deliberate.

To publish it when ready:

```bash
export SPARKLE_BIN=/path/to/Sparkle/bin        # or put generate_appcast on PATH
Scripts/release/sparkle-appcast.sh
# then commit docs/appcast.xml and push — enclosure URLs must point at the
# GitHub Release assets, not at raw docs/
```

Note the appcast flow needs a signed **zip**, which the DMG build does not
produce; prior releases staged one under `Artifacts/release/sparkle/`.

## Also not done

- **Not notarized, not Developer ID signed** — ad-hoc by design (ADR 0008).
- **Homebrew cask not updated** (`Scripts/release/homebrew/`).
- The two 23 MB zips remain in git history; removing them is a history rewrite
  and needs its own authorization.
- Remaining plan slices: max concurrent downloads, renew stale URL, per-job
  limit setter, duplicate detection, shutdown-on-drain, proxy auth, named
  queues, recurring scheduling, full HLS/DASH.
