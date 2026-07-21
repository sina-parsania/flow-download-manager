# Contributing to Download Manager

Thanks for your interest in contributing. Download Manager is a native macOS
download manager (macOS 14.0+, Apple Silicon only) built as a main app plus a
per-user `DownloadEngineAgent` LaunchAgent communicating over an authenticated,
versioned XPC interface.

The project is at **Phase 0 — repository foundation**. There are no shipping user
download features yet; contributions at this stage strengthen the build system,
policies, architecture scaffolding, tests, and tooling. Contributions are accepted
under **GPL-3.0-or-later** (see [License](#license)).

Before writing code, read [`AGENTS.md`](AGENTS.md) — it is the authoritative
operating guide and defines the module layering and architecture boundaries that
reviews enforce.

## Prerequisites

- macOS 14.0 or later.
- Apple Silicon (arm64). Intel is not supported; `make doctor` fails on
  unsupported toolchains.
- Xcode 26 (stable release).
- [Homebrew](https://brew.sh) (used to install pinned developer tools).

## Setup

Install the pinned developer tools, then verify your environment:

```bash
make bootstrap-tools   # install pinned dev tools (xcodegen, swiftformat, swiftlint)
make doctor            # toolchain report; fails on Intel/unsupported setups
```

A few things to know about the build layout:

- **The `.xcodeproj` is generated and gitignored.** `DownloadManager.xcodeproj`
  is produced by [XcodeGen](https://github.com/yonaskolb/XcodeGen) from
  [`project.yml`](project.yml), which is the single source of truth. Do not
  hand-edit the project. Regenerate it with:

  ```bash
  make project
  ```

- **The first-party module graph lives in a local SwiftPM package.**
  [`Package.swift`](Package.swift) declares the reusable modules (the `DownloadKit`
  product set: `Domain`, `XPCContracts`, `Persistence`, `SharedObservability`,
  `SharedSecurity`, `EngineAgent`, and the `XPCSecuritySupport` shim). The Xcode
  project hosts only the app + agent executables and the test bundles.

## Development loop

Run the fast gate before every push:

```bash
make verify-fast   # format-check, lint, build-debug, unit tests, incomplete-work scan
```

Run the full gate before opening or updating a pull request, and whenever a change
could affect integration, recovery, performance, or concurrency behavior:

```bash
make verify        # full stable gate + evidence bundle under Artifacts/validation/
```

`make help` lists every available target.

## Non-negotiable gates

These are enforced by tooling and by review. Do not weaken a gate to make a check
pass; fix the underlying code.

- **Swift 6 language mode with complete strict concurrency.**
- **Warnings-as-errors for first-party code** (Swift and C/C++/ObjC). Lint rules
  are not disabled.
- **No banned incomplete-work tokens** in first-party source, tests, or CI scripts:
  `TODO`, `FIXME`, `HACK`, `TEMP`, `PLACEHOLDER`, `NOT_IMPLEMENTED`,
  `fatalError("Not implemented…")`, and skipped/focused test markers
  (`XCTSkip`, `.skip(`, `.only(`). `make incomplete-work-scan` must pass.
- **No `try!` and no `as!`** in first-party Swift (absolute).
- **No force-unwrap (`!`) in production Swift**, except audited,
  mechanically-guaranteed generated constants that are explicitly allowlisted.
- **No empty or broadly-silent `catch`** blocks.
- **No skipped, disabled, or focused-only tests.**
- **No code, UI, or schema for a future phase.** In-scope work is complete;
  out-of-scope work is absent — no target, no stub, no dead flag. A deferred
  requirement is removed from committed scope, not left half-implemented.

Architecture-boundary rules (one-directional layer imports; the UI never writes
persistence or owns transfer state; only the agent writes the database) live in
[`AGENTS.md`](AGENTS.md). Import-layering violations fail review.

## Pull requests

- **Keep PRs small and focused.** One concern per PR; smaller changes are easier to
  review and to verify.
- **Tests are required.** New behavior ships with tests; changed behavior updates
  them. `make verify` must be green.
- **Keep traceability up to date.** When a change touches a requirement, update the
  matching row in
  [`macos-download-manager-prompt-pack/10-traceability-matrix.md`](macos-download-manager-prompt-pack/10-traceability-matrix.md)
  in the same change.

### CI and authorization policy

- CI on pull requests **must never sign, notarize, or use production secrets.**
  Pull-request automation builds and validates only.
- **Commits, pushes, and releases require explicit human authorization.** Prepare
  commands locally, but obtain approval immediately before committing or rewriting
  history, pushing/fetching/pulling, or creating or editing releases. Approval for
  one action does not authorize the next.

### Developer Certificate of Origin

Please sign off your commits to certify that you have the right to submit the
contribution under the project license (see the
[Developer Certificate of Origin](https://developercertificate.org)):

```bash
git commit -s
```

This adds a `Signed-off-by:` trailer to your commit message.

## License

By contributing, you agree that your contributions are licensed under
**GPL-3.0-or-later**, the same license as the project (see [`LICENSE`](LICENSE)).
New source files should carry the `SPDX-License-Identifier: GPL-3.0-or-later`
header.
