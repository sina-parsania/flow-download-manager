# ADR 0008 — Community GitHub distribution without Developer ID

- Status: Accepted
- Date: 2026-07-23

## Context

Apple’s Gatekeeper prefers Developer ID–signed and notarized apps for drag-and-drop
installs. The Apple Developer Program is paid. This project is GPL-3.0-or-later and
is intended for free use from GitHub. Many open-source macOS tools ship the same
way: unsigned or ad-hoc builds plus explicit “Open anyway” instructions.

## Decision

1. **Primary distribution** is GitHub source + optional **unsigned** Release DMG
   (`Scripts/release/build-dmg.sh`). No paid Developer ID is required.
2. Users install by building from source, or by clearing quarantine / using
   Finder → Open (documented in `Documentation/install-from-github.md`).
3. Developer ID signing + notarization remain **optional** scripts for a future
   maintainer who already has credentials. They are not a gate for community
   releases.
4. Do not claim Apple notarization in README or release notes for unsigned builds.

## Consequences

- First launch may show Gatekeeper warnings; that is expected.
- Phase 5 “community complete” = verify + SBOM + unsigned DMG + install docs.
- Phase 5 “Apple notarized complete” stays optional and credential-gated.
