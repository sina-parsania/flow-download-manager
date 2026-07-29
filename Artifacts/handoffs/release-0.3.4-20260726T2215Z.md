# Handoff — release 0.3.4

**COMPLETE**

## Artifacts
- `Artifacts/release/DownloadManager-0.3.4-unsigned.dmg`
- `Artifacts/release/DownloadManager-0.3.4-unsigned.dmg.sha256` → `7ec2bee43d34afdd8927a88c7271f908828fc4887f93d48a558bd029f1290af2`
- `Artifacts/release/sbom.txt`
- `Artifacts/release/Flow-0.3.4.zip` (Sparkle attachment; appcast not regenerated — no `generate_appcast` on PATH)

## Evidence
```
make verify-fast          # exit 0
make test-integration     # 59 tests, 0 failures
make test-recovery        # 9 tests, 0 failures
make release-sbom         # exit 0
make release-dmg-unsigned # exit 0
```

## Published
- Commit `64bca3a` on `main`
- Tag `v0.3.4`
- Release: https://github.com/sina-parsania/flow-download-manager/releases/tag/v0.3.4

## Not done
- Track B notarization (skipped; ADR 0008)
- Sparkle `docs/appcast.xml` / `Resources/Updates/appcast.xml` not updated (no Sparkle tools / EdDSA signing in this environment)
