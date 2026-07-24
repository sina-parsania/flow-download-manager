# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Flow Download Manager** — native macOS 14+, **arm64 only**, Swift 6 complete concurrency, warnings-as-errors. SwiftUI app + a per-user `DownloadEngineAgent` talking over versioned authenticated XPC. Distributed unsigned/ad-hoc from GitHub ([ADR 0008](Documentation/adr/0008-community-github-distribution.md)). GPL-3.0-or-later.

[`AGENTS.md`](AGENTS.md) is the terse operating contract — read it too. This file adds the things that only show up after you've been burned.

---

## RULE 0 — `make verify-fast` is NOT the gate

`verify-fast` = format-check + lint + build-debug + **unit tests only** + incomplete-work scan. It does **not** run integration, recovery, performance, fuzz, or the sanitizers.

A prior slice shipped "green on `verify-fast`" while the integration lane was **red** — two segmented-transfer tests had been failing and nobody saw it. Never declare transfer, persistence, or XPC work done on `verify-fast` alone.

```bash
make verify-fast        # fast inner loop — necessary, never sufficient
make test-integration   # ALWAYS run this for TransferCore / TransferCurlBridge / CCurl / Persistence / EngineAgent
make test-recovery      # resume, crash-boundary, requeue
make test-asan          # REQUIRED for any C or curl-handle-lifetime change
make test-tsan          # REQUIRED for any concurrency or shared-state change
make verify             # everything + evidence bundle under Artifacts/validation/
```

## RULE 1 — `make lint` degrades silently

If SwiftLint isn't installed it prints `lint: swiftlint not installed; using grep safety backstop` **and passes anyway**. A green `make lint` locally can mean "nothing was linted." CI runs the real thing. Check the line, don't trust the exit code.

## RULE 2 — Trust the code, not the comment

Comments in this repo have been wrong in ways that cost real time:

- A byte-size helper documented as "Cheap, caller-side size estimate" ran a full `NSKeyedArchiver` secure-coding pass over the entire job list on **every** poll.
- `runSegmentedRanges` promised "siblings run to completion and their bytes stay recorded" long after a refactor made one range failure tear down every other in-flight connection.
- `LibraryModel` claimed search was "debounced at the view" when nothing debounced it.

Before relying on a comment for a decision, verify it. When you change behaviour, the comment is part of the change.

## RULE 3 — Remote and destructive actions need authorization *immediately before*

Prepare locally, then ask. Applies to: commit, history rewrite, push/fetch/pull, GitHub releases/issues/PRs, publishing the Chrome extension, signing/notarizing, uploading artifacts, deleting user files or databases. Approval for one action does not authorize the next. See `AGENTS.md` → Remote-action approval policy.

## RULE 4 — Verify the baseline before you review or plan

The working tree here is frequently dirty with in-flight slices, and more than one session may be editing at once. A plan written against "commit `X`" while the tree carried 600+ uncommitted lines was stale before it was finished, and files were rewritten mid-review.

Start with `git status --short` and `git diff --stat`. If the tree is dirty, say so and review the tree, not the commit.

---

## Strict gates — never weaken to pass

- Swift 6 language mode, **complete** strict concurrency. Warnings are errors (Swift and C).
- No `TODO/FIXME/HACK/TEMP/PLACEHOLDER/NOT_IMPLEMENTED`, no `fatalError("not implemented")`, no empty/broad silent `catch`, no skipped tests. Out-of-scope work is **absent** — no target, no stub. Enforced by `make incomplete-work-scan`.
- No `try!`, `as!`, or force-unwrap on untrusted data in first-party Swift.
- No shell interpretation for subprocesses — executable URL + argument array only.
- No secrets, paths, URLs-with-query, headers, or cookies in logs/fixtures/snapshots without redaction **at the interpolation source**.

Going faster is never a reason to relax any of these, and neither is a failing test.

## SwiftFormat rules that bite

Lint runs before build, so these fail the whole gate on a one-character mistake:

- `docComments` — `///` only on declarations. A `///` on a local `var` is an error; use `//`.
- `redundantSelf` — inside an actor-isolated closure that already unwrapped `self`, write `recordProgress(...)`, not `self.recordProgress(...)`.

---

## Architecture

Imports flow one direction. A violation fails review.

```
Domain  ──►  XPCContracts  ──►  Persistence  ──►  EngineAgent      (sole DB writer)
   │                │                                  ▲
   └────────────────┴──────────►  Presentation  ────────┘ (XPC only)
                                        │
                                       App  (SwiftUI @main, embeds the agent)
```

- **`Domain`** — pure Swift value types + state machines. Imports **nothing** platform: no AppKit/SwiftUI/GRDB/XPC/Security. `Sendable`, persistence-agnostic.
- **`XPCContracts`** — `NSSecureCoding` DTOs + `EngineControlProtocol`. Every RPC needs coordinated edits in `EngineControlProtocol.swift`, `EngineControlInterface.swift`, `EngineService.swift`, and `EngineClient.swift` — those four files move together, by design.
- **`Persistence`** — GRDB repositories + migrations.
- **`EngineAgent`** — XPC listener, peer identity validation, `TransferOrchestrator`. **The only process that writes the database or moves a job into an active transfer state.**
- **`Presentation`** — SwiftUI + AppKit. Never writes persistence directly, never owns sockets or partial files.

**The process rule that governs everything:** the UI never owns sockets, partial files, checkpoints, or the queue. If a change makes the UI touch any of those, it is the wrong change.

### Engine transport — two paths, one Mach name

- **Bundled XPC service** (`Contents/XPCServices/DownloadEngineAgent.xpc`, demand-launched via `NSXPCConnection(serviceName:)`) — the ad-hoc/unsigned path, and the default for community builds.
- **LaunchAgent / SMAppService** — for signed installs only.

On macOS 26+, `NSXPCListenerEndpoint` can only be encoded by `NSXPCCoder`, so the old "spawn a child and hand off an endpoint file" handshake is dead. Don't resurrect it.

### Transfer hot path

`TransferOrchestrator` → `SegmentedTransfer` → `CurlMultiLoop` → `CCurl/DMCurlSupport.c` → pinned static libcurl.

- **`SegmentLedger` / `.segmap`** is the authority on what is actually on disk. Once a partial is preallocated with `ftruncate`, its file size is meaningless — only the segment map knows. **A probe failure must never wipe a partial**; propagate the error so the retry path keeps the bytes.
- The ledger tiles **finer** than the connection count (≤128 chunks); `maxConcurrent` bounds how many are live. That gap is the whole point: when a connection frees up it refills from the pending queue, so one slow connection only ever holds a small tile. Measured effect: **coarse 4.37 s → fine 0.75 s (5.83×)** on the straggler benchmark.
- `CURLMOPT_PIPELINING = CURLPIPE_NOTHING` is load-bearing. Without it HTTP/2 folds every segment onto one connection and segmentation buys nothing.
- Durability is owned by the **Swift** layer — one `fsync` after the map loop. Do not add per-easy `fsync` back into the C shim; with 32 segments sharing one fd that was 32 redundant full-file syncs.

---

## Commands

```bash
make doctor              # toolchain report; fails on Intel/unsupported
make bootstrap-tools     # install pinned xcodegen, swiftformat, swiftlint
make project             # REQUIRED after editing project.yml
make build-debug
make format              # apply formatting (format-check only lints)
```

`DownloadManager.xcodeproj` is **generated from `project.yml` by XcodeGen and gitignored**. Never hand-edit it. Adding a source directory or a target dependency means editing `project.yml` then `make project`.

### Running a single test

Lanes map to Xcode targets: `UnitTests`, `IntegrationTests`, `RecoveryTests`, `PerformanceTests`, `UITests`.

```bash
# one test class
xcodebuild -project DownloadManager.xcodeproj -scheme DownloadManager \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  -only-testing:IntegrationTests/SegmentedTransferIntegrationTests test

# one test method
xcodebuild ... -only-testing:UnitTests/JobRepositoryTests/testFetchJobRowsStatementCount test
```

### Throughput benchmark

```bash
make test-performance    # includes TransferThroughputTests (scaling + straggler tail)
make performance-baseline    # writes Artifacts/baselines/candidate-<stamp>.json
make performance-compare BASELINE=Artifacts/baselines/<approved>.json
```

`performance-compare` **fails closed** when there are no numeric metrics — a non-zero exit there means "no evidence yet", not "regression". Don't read a green run as proof until `"metrics"` is actually populated.

---

## Test fixtures — sizes are semantic

`FaultHTTPServer` serves deterministic loopback fixtures. The size you pick decides which code path you exercise:

| route | size | what it exercises |
|---|---|---|
| `/fixtures/ok` | 4 KiB | **always tiles to 1 segment** — cannot test segmentation |
| `/fixtures/large` | 2 MiB | real multi-segment plan (lands in the 1–8 MiB band) |
| `/fixtures/throughput?size=&kbps=&slowFirst=&slowKbps=` | configurable | rate-capped; the only way to measure parallelism or a straggler |

Two tests named `...TwoSegment...` sat green-then-red for a long time asserting `segmentCount == 2` against the 4 KiB fixture, which `preferredSegmentCount` always tiles to 1. **Check `preferredSegmentCount` before picking a fixture size.**

Rate caps matter because an uncapped loopback transfer finishes instantly and parallelism becomes invisible. A benchmark that cannot fail is worth nothing — the straggler test compares coarse vs fine tiling under identical conditions so a regression in the refill loop actually breaks it.

---

## What you cannot read

The normative specification pack (`00-master-plan.md`, `03-design-system-ui-ux.md`, `04-domain-and-data-contracts.md`, `05-quality-testing-release-gates.md`, `07-handoff-protocol.md`, `08-validation-commands.md`) is **kept local and gitignored**. Source comments and ADRs cite it constantly — those references are dead ends for you and for outside contributors. Don't hunt for those files; work from `AGENTS.md`, the ADRs in `Documentation/adr/`, and the code.

## Handoffs

Every work slice ends with `Artifacts/handoffs/<slice>-<UTC>.md`, led by `COMPLETE | INCOMPLETE | BLOCKED` with raw command output as evidence. State what was **not** done as explicitly as what was.

## ADRs — decided, don't re-litigate

`Documentation/adr/`: 0001 build system (XcodeGen) · 0002 warnings-as-errors scope (per-target, not on the xcodebuild command line — a global override breaks vendor SPM builds) · 0003 XPC client identity · 0004 test lanes · 0005 libcurl TLS backend · 0006 libtorrent deferred · 0007 Chrome native messaging · 0008 community GitHub distribution.

`TorrentCore` and `MediaIsolation` ship in **Presentation** for Compose inspection /
optional yt-dlp probes only. They are **not** transfer engines. BitTorrent download
and signed Safari distribution stay deferred (ADR 0006 / 0008).
