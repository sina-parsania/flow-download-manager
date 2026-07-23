# AGENTS.md — Download Manager

Authoritative operating guide for coding agents in this repository. Read this and
the linked contracts before editing. The normative specification lives in
the private specification pack (kept local, not published); this
file is the terse working summary.

## What this is

A native macOS (14.0+, arm64-only) download manager built as a main app plus a
per-user `DownloadEngineAgent` LaunchAgent that talk over versioned, authenticated
XPC. Distribution is **GitHub community builds** by default (unsigned / ad-hoc OK;
see ADR 0008). Optional Developer ID notarization is supported but **not required**.
License: `GPL-3.0-or-later`. Current state: **Phases 1–5 community path in progress** —
Universal Transfer + Chrome Native Messaging + media/torrent/release plumbing landed;
manual VoiceOver and optional notarization remain open.

## Build & test commands

The stable interface is `make` (see `08-validation-commands.md` in the private spec pack).
The `.xcodeproj` is generated from `project.yml` by XcodeGen and is gitignored —
run `make project` (or `make bootstrap-tools` first on a clean machine).

```bash
make doctor              # environment/toolchain report; fails on Intel/unsupported
make bootstrap-tools     # install pinned dev tools (xcodegen, swiftformat, swiftlint)
make project             # regenerate DownloadManager.xcodeproj from project.yml
make verify-fast         # format-check, lint, build-debug, unit tests, incomplete-work scan
make verify              # full stable gate + evidence bundle under Artifacts/validation/
```

Core build is `xcodebuild -project DownloadManager.xcodeproj -scheme DownloadManager
-destination 'platform=macOS,arch=arm64'` with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.

## Strict gates (never weaken to pass a test)

- Swift 6 language mode, **complete** strict concurrency.
- Warnings are errors (Swift, C/C++/ObjC). No disabling of lint rules.
- No `TODO/FIXME/HACK/TEMP/PLACEHOLDER/NOT_IMPLEMENTED`, no `fatalError("not implemented")`,
  no empty/broad silent `catch`, no skipped/focused tests in first-party source.
  In-scope work is complete; out-of-scope work is **absent** (no target, no stub).
- No `try!`, no `as!`, no force-unwrap `!` on untrusted data in first-party Swift
  (audited generated constants excepted and allowlisted).
- No shell interpretation for subprocesses; executable URL + argument array only.
- No secrets/paths/URLs-with-query/headers/cookies in logs, fixtures or snapshots
  without redaction at the interpolation source.
- `git grep`-based `make incomplete-work-scan` must pass (this repo is a git repo so
  the scan actually inspects files).

## Architecture boundaries

Layer imports flow one direction; violations fail review.

- `Domain` — pure Swift value types + state machines. Imports **nothing** platform
  (no AppKit/SwiftUI/GRDB/XPC/Security). `Sendable`, persistence-agnostic.
- `XPCContracts` — secure-coding DTOs + the `EngineControlProtocol`. Depends on Domain.
- `Persistence` — GRDB repositories/migrations. Agent is the **sole writer**.
- `SharedSecurity` / `SharedObservability` — Keychain + redaction / logging.
- `XPCSecuritySupport` — tiny ObjC shim isolating the `NSXPCConnection.auditToken`
  SPI used for peer code-signing validation (Developer ID only).
- `EngineAgent` — agent core (XPC listener, identity validation). Sole DB writer.
- `Presentation` — SwiftUI + AppKit integrations. Never writes persistence directly.
- `App` — SwiftUI `@main`; owns UI resources; embeds the agent.

Process rule: the UI never owns sockets, partial files, checkpoints or the queue.
Only the agent moves a job into an active transfer state or writes the database.

## Remote-action approval policy

Prepare commands locally, but obtain **explicit human authorization immediately
before**: committing/rewriting history, push/fetch/pull, creating/editing GitHub
releases/issues/PRs, publishing the Chrome extension, signing/notarizing with
protected credentials, uploading an appcast/artifact, or deleting user
files/databases/backups. Approval for one action does not authorize the next.
CI on pull requests never signs, notarizes or requires production secrets.

## Handoff

Every phase ends with `Artifacts/handoffs/<phase>-<UTC>.md` per
`07-handoff-protocol.md` in the private spec pack,
led by `COMPLETE | INCOMPLETE | BLOCKED` with raw command/artifact evidence.
