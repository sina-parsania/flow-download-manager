# Phase 5 — Release checklist

Two tracks. **Community GitHub** is the default and does **not** need Developer ID.

## Track A — Community GitHub (default)

Goal: free source + unsigned DMG others can run with one Gatekeeper bypass.

1. `make verify` (or at least `make verify-fast` + `make test-integration`)
2. `make release-sbom`
3. `make release-dmg-unsigned` → `Artifacts/release/DownloadManager-*-unsigned.dmg`
4. Confirm [install-from-github.md](install-from-github.md) matches the artifact name
5. GitHub Release: attach unsigned DMG + SBOM; say clearly **not notarized**
6. Prefer tagging a reviewed commit; never attach signing secrets

**Community Phase 5 done** when the above are published. Gatekeeper warnings are
expected and documented.

## Track B — Optional Developer ID (paid Apple Program)

Only if a maintainer already has credentials and wants quieter first-launch UX:

1. Developer ID Application certificate  
2. Codesign app + embedded agent + ChromeNativeHost  
3. `Scripts/release/notarize.sh <signed.dmg>`  
4. Staple + Gatekeeper check  
5. Optional Sparkle keys / appcast  

Do **not** block community releases on Track B.

## Do not

- Commit signing identities or notary API keys  
- Auto-notarize from PR CI  
- Claim “Apple notarized” for unsigned builds  
