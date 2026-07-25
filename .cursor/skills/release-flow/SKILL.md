---
name: release-flow
description: >-
  Ships a Flow Download Manager community GitHub release (unsigned DMG, SBOM,
  optional Sparkle appcast). Use when the user asks to release, cut a version,
  publish a DMG, update appcast, or run Track A / Track B packaging.
---

# release-flow

Default track is **community GitHub** (ADR 0008): unsigned / ad-hoc OK.
Developer ID notarization is optional Track B — never block Track A on it.

**Remote actions need explicit human approval immediately before each step:**
commit, tag, push, `gh release`, uploading artifacts, publishing Chrome
extension, signing/notarizing with credentials. Approval for one does not
authorize the next.

## 0. Preconditions

```bash
git status --short
git diff --stat
cat VERSION
head -40 CHANGELOG.md
```

- Working tree dirty with unrelated WIP → stop and say so; do not ship mixed slices.
- Version in `VERSION`, `CHANGELOG.md`, and marketing strings must agree.
- Read `Documentation/release-checklist.md` if anything is unclear.

## 1. Quality gate (before packaging)

Minimum for a community cut:

```bash
make verify-fast
make test-integration
```

Prefer full `make verify` when time allows (recovery, performance, asan, tsan,
fuzz, analyze). `verify-fast` alone is **never** enough for transfer /
Persistence / XPC / CCurl changes.

Watch for silent lint: if `make lint` prints
`swiftlint not installed; using grep safety backstop`, say so — CI still runs
real SwiftLint.

## 2. Package Track A (default)

```bash
make release-sbom
make release-dmg-unsigned
```

Artifacts:

- `Artifacts/release/DownloadManager-<VERSION>-unsigned.dmg`
- `Artifacts/release/DownloadManager-<VERSION>-unsigned.dmg.sha256`
- `Artifacts/release/sbom.txt`

Confirm `Documentation/install-from-github.md` still matches the DMG name pattern.

Optional Sparkle zip + feed (only with maintainer EdDSA key in Keychain):

```bash
Scripts/release/sparkle-appcast.sh   # updates docs/appcast.xml
```

Never commit Sparkle private keys. Public key stays in Info.plist `SUPublicEDKey`.

## 3. Publish (after explicit approval)

Typical sequence — **ask before each remote step**:

1. Commit release metadata (`VERSION`, `CHANGELOG.md`, `docs/appcast.xml`, …)
2. Tag `vX.Y.Z` on the reviewed commit
3. `git push` + push tag
4. Create GitHub Release and attach DMG + sha256 + SBOM (+ Sparkle zip if used)

```bash
gh release create "vX.Y.Z" \
  "Artifacts/release/DownloadManager-X.Y.Z-unsigned.dmg" \
  "Artifacts/release/DownloadManager-X.Y.Z-unsigned.dmg.sha256" \
  "Artifacts/release/sbom.txt" \
  --title "vX.Y.Z" \
  --notes-file -   # or --generate-notes; must say NOT notarized
```

Release notes must state clearly: **not Developer ID signed / not Apple notarized**.
Point installers at `Documentation/install-from-github.md` / `Scripts/install.sh`.

## 4. Track B — optional Developer ID

Only when credentials exist and the user asks:

```bash
DM_CODESIGN_IDENTITY='Developer ID Application: …' make release-codesign APP=…/DownloadManager.app
make release-notarize DMG=…/signed.dmg
```

`codesign.sh` / `notarize.sh` **fail closed** (exit 2) without credentials — that is
correct for community path, not a broken release.

## 5. Do not

- Claim “Apple notarized” for unsigned builds
- Auto-notarize from PR CI
- Commit signing identities, notary API keys, or Sparkle private keys
- Attach secrets to the GitHub Release
- Ship while `make incomplete-work-scan` would fail

## 6. Report

Lead with `COMPLETE | INCOMPLETE | BLOCKED`. List artifact paths, sha256, tag,
release URL (if published), and what was **not** done (e.g. Track B skipped,
Sparkle feed unpublished). Write
`Artifacts/handoffs/release-<VERSION>-<UTC>.md` when finishing a real cut.
