# Phase 5 — Release owner checklist

Status: local plumbing only. Signing/notarization/Sparkle keys are **BLOCKED**
without Developer ID and release credentials.

## Local (no secrets)

1. `make verify`
2. `Scripts/release/generate-sbom.sh`
3. `Scripts/release/build-dmg.sh` → unsigned DMG under `Artifacts/release/`
4. Review `THIRD_PARTY_NOTICES.md`, `DEPENDENCIES.md`, privacy/security docs

## Requires human + credentials

1. Developer ID Application + Installer certificates in CI-isolated machine
2. Hardened Runtime entitlements review
3. `codesign` app + embedded agent + Sparkle XPC if any
4. `Scripts/release/notarize.sh <signed.dmg>` with `DM_NOTARY_PROFILE` or API key
5. Staple + gatekeeper assessment
6. Sparkle EdDSA keypair; fill `Artifacts/release/appcast.example.xml`
7. GitHub Release draft — **explicit human approval** before publish
8. Clean-machine install/upgrade/rollback audit

## Do not

- Commit signing identities or notary API keys
- Auto-publish from PR CI
- Claim Phase 5 COMPLETE without stapled notarized DMG evidence
