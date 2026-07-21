# ADR 0002 — Warnings-as-errors scope and module build mode

Status: accepted (Phase 0)

## Context

First-party Swift/ObjC/C must build clean with warnings as errors
(`00-master-plan.md` §8, `05-quality-testing-release-gates.md` §6). Vendor
sources are explicitly excluded from the style/warnings gate (§6). The canonical
build command in `08-validation-commands.md` §4 shows
`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES` on the
`xcodebuild` line.

Two concrete problems arose:

1. Passing those flags on the `xcodebuild` command line applies them to **every**
   target, including the GRDB SwiftPM target, which builds with `-suppress-warnings`.
   The Swift driver then fails: `conflicting options '-warnings-as-errors' and
   '-suppress-warnings'`.
2. Xcode's explicit module builds fail to resolve GRDB 7's internal `GRDBSQLite`
   C module into dependent targets.

## Decision

- Warnings-as-errors is scoped to **first-party targets only**:
  - module targets set it via `swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]`
    in `Package.swift`;
  - app/agent/test targets set `SWIFT_TREAT_WARNINGS_AS_ERRORS`/
    `GCC_TREAT_WARNINGS_AS_ERRORS` via `Configuration/Shared.xcconfig`.
- The flags are **not** passed on the `xcodebuild` command line (which would hit
  vendor targets). This is a faithful, better-scoped realization of §4's intent:
  vendor sources are out of the warnings gate by policy.
- `SWIFT_ENABLE_EXPLICIT_MODULES = NO` (implicit modules) so `GRDBSQLite`
  resolves via package module search paths.
- `ENABLE_USER_SCRIPT_SANDBOXING = NO`: the sandbox denies Xcode's own
  "Copy Swift Objective-C Interface Header" `ditto` step for library modules on
  the build volume. It hardens build-time scripts only, not the shipped app, and
  is not a release gate.

## Consequences

- First-party warnings-as-errors is genuinely enforced; a first-party warning
  fails the build. Verified by the clean Phase 0 build.
- Vendor (GRDB) builds with its own settings and does not pollute the gate.
- If a future Xcode reliably resolves `GRDBSQLite` under explicit modules, the
  flag can be removed and this ADR superseded.
