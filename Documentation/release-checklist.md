# Release checklist

Two tracks. **Community GitHub** is the default and does **not** need Developer ID.

## Track A — Community GitHub (default)

Goal: free source + unsigned DMG others can run with one Gatekeeper bypass.

1. `make verify` (or at least `make verify-fast` + `make test-integration`)
2. `make release-sbom`
3. `make release-dmg-unsigned` → `Artifacts/release/DownloadManager-*-unsigned.dmg`
4. Confirm [install-from-github.md](install-from-github.md) matches the artifact name
5. Optional: build a Sparkle zip + `Scripts/release/sparkle-appcast.sh` → commit `docs/appcast.xml`
6. GitHub Release: attach unsigned DMG + SBOM (+ Sparkle zip if using in-app updates); say clearly **not notarized**
7. Prefer tagging a reviewed commit; never attach signing secrets / Sparkle private keys

**A community release is done** when the above are published. Gatekeeper warnings
are expected and documented. This is the track v0.2.0 shipped on.

## Track B — Optional Developer ID (paid Apple Program)

Only if a maintainer already has credentials and wants quieter first-launch UX:

1. Developer ID Application certificate  
2. `DM_CODESIGN_IDENTITY='Developer ID Application: …' make release-codesign APP=…/DownloadManager.app`  
3. `Scripts/release/notarize.sh <signed.dmg>` (or `make release-notarize DMG=…`)  
4. Staple + Gatekeeper check  
5. Sparkle appcast (same EdDSA key as community; Apple codesign is separate)  

Do **not** block community releases on Track B. Both `codesign.sh` and
notarize.sh **fail closed** when credentials are absent (exit 2) — that is
success for the community path, not a broken release.

## Sparkle notes

- Public key: `SUPublicEDKey` in the app Info.plist  
- Private key: maintainer Keychain only (`generate_keys`); never commit  
- Feed: `docs/appcast.xml` on `main` (`SUFeedURL`); bundled `Resources/Updates/appcast.xml` is a fallback when the remote feed is missing  
- Helper: `Scripts/release/sparkle-appcast.sh`  
- Until `docs/appcast.xml` is pushed, Check for Updates uses the bundled empty feed (“You’re up to date”) instead of erroring

## Do not

- Commit signing identities or notary API keys  
- Auto-notarize from PR CI  
- Claim “Apple notarized” for unsigned builds  
