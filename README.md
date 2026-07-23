# Download Manager

Native macOS (Apple Silicon) download manager — **GPL-3.0-or-later**.

Distributed **from GitHub for free**. No Mac App Store. No paid Apple Developer ID
required for community use ([ADR 0008](Documentation/adr/0008-community-github-distribution.md)).

## Requirements

- macOS 14+  
- Apple Silicon (arm64)  
- Xcode (to build)

## Quick start

```bash
make bootstrap-tools
make verify-fast
```

Install / Gatekeeper notes: [Documentation/install-from-github.md](Documentation/install-from-github.md).

## Unsigned release package

```bash
make release-sbom
make release-dmg-unsigned
```

Artifacts land under `Artifacts/release/`. Optional notarization exists only if
someone later brings their own credentials (`make release-notarize`) — not needed
for GitHub community releases.

## License

GPL-3.0-or-later. See `LICENSE`.
