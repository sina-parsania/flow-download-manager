# COMPLETE — release v0.3.1

UTC: 20260725T0131Z

## Evidence
- make verify-fast: OK (369 unit tests)
- make test-integration: OK (30 tests)
- make release-sbom + make release-dmg-unsigned
- DMG: Artifacts/release/DownloadManager-0.3.1-unsigned.dmg
- SHA256: 3bb7598c9904cb4dd7c990102bd193d45c1d8a81379c6d77fd3f698df753f827
- Tag: v0.3.1 @ c55fecd
- GitHub: https://github.com/sina-parsania/flow-download-manager/releases/tag/v0.3.1

## Not done
- Track B Developer ID / notarize (not requested)
- Sparkle appcast zip/feed update (optional; key in Keychain)
- full `make verify` (recovery/asan/tsan/perf) — not run for this cut
