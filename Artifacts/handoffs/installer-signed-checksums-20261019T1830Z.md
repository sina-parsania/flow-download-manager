# INCOMPLETE — installer verifies a signed checksum (signatures not uploaded yet)

UTC: 20261019T1830Z
Branch: `chore/sort-installer-and-cleanup` (local only)

## Changes

- `Scripts/install.sh`: embeds the release public key; requires
  `<dmg>.sha256.sig`, verifies it with stock `ssh-keygen -Y verify` (namespace
  `flow-release`) before trusting the checksum. Two duplicate asset-lookup
  heredocs collapsed into `asset_url`.
- `Scripts/release/sign-checksum.sh` (new): signs a `.sha256`, refuses a key that
  does not match the one embedded in `install.sh`, and verifies the fresh
  signature the way the installer does.
- `Scripts/release/publish.sh`: preflight probe-signs before the build; signs the
  DMG checksum after it; commits and uploads the `.sig`.
- Key: `~/.config/flow/release-signing-ed25519` (outside the repo, mode 600, no
  passphrase). Fingerprint `SHA256:jrDeqzLB411iKnz1l2jjVbFWj38FSytgFxKLAzIskfo`.
- 11 existing releases signed retroactively. Each GitHub `.sha256` was first
  compared byte-for-byte with the copy committed in git.
- **v0.3.0 not signed.** GitHub checksum `b157cef7…` ≠ committed `f9650af0…`.
  The release was published 2026-07-24 23:52; `project.yml` went to 0.3.0 only on
  2026-07-25, and the committed checksum dates from 2026-07-29 — it records a later
  local rebuild, so it cannot vouch for the published file. The installer refuses
  `--tag v0.3.0`.

## Evidence

- Sign + verify of the 0.4.5 checksum: OK; tampered checksum: rejected; wrong key:
  `signing key does not match the key embedded in Scripts/install.sh`
- Documented manual check on 0.4.5: `Good "flow-release" signature…`,
  `DownloadManager-0.4.5-unsigned.dmg: OK`
- `bash -n` on install.sh, publish.sh, sign-checksum.sh: OK

## Not done

- `.sig` assets not uploaded to GitHub releases. **They must be uploaded before
  this branch reaches `main`**: `install.sh` is served from `main`, and without
  them every one-line install fails closed.
- End-to-end `install.sh --tag v0.4.5` run (needs the uploaded `.sig`).
- Key backup — only copy is on the internal disk.
