---
name: verify-scope
description: Run the test lanes that actually cover the files you changed. Use before declaring any Flow work done, and whenever someone says "is it green?", "verify", "run the tests", or "ready to commit". `make verify-fast` alone is never sufficient for transfer, persistence, XPC, or C changes.
---

# verify-scope

`make verify-fast` runs format-check, lint, a Debug build, **unit tests only**, and the incomplete-work scan. It does not run integration, recovery, performance, fuzz, or the sanitizers. A slice once shipped "green on verify-fast" with two segmented-transfer integration tests red.

This skill picks lanes from what actually changed.

## 1. Determine scope

```bash
git status --short
git diff --stat
```

If the tree is dirty with work you did not write, **say so before reporting anything** — more than one session may be editing, and a lane failure in someone else's file is not yours to claim or to hide.

## 2. Map changed paths to lanes

| changed | lanes required |
|---|---|
| `Sources/CCurl/**` | verify-fast · test-integration · test-recovery · **test-asan** · **test-tsan** |
| `Sources/TransferCore/**`, `Sources/TransferCurlBridge/**` | verify-fast · test-integration · test-recovery · test-asan · test-tsan |
| tiling / `maxConcurrent` / refill loop / segment policy | + **test-performance** |
| `Sources/EngineAgent/**`, `Sources/Persistence/**` | verify-fast · test-integration · test-recovery |
| `Sources/XPCContracts/**` | verify-fast · test-integration (+ a `XPCCodingTests` case for any new DTO) |
| `Sources/Presentation/**`, `Sources/App/**` | verify-fast (+ test-ui if UI automation touched) |
| `project.yml` | `make project` first, then the lanes for whatever it added |
| release scripts, `Makefile` | verify-fast · the affected target, run explicitly |

Everything, before a release: `make verify`.

## 3. Run them, then read the output

Do not grep only for `SUCCEEDED`. Check the executed-test counts — a lane that builds nothing and runs nothing exits 0.

Two known-silent failures:

- **`make lint` prints `swiftlint not installed; using grep safety backstop` and passes anyway.** If you see that line, SwiftLint did not run. Say so; do not report "lint passed".
- **`make performance-compare` fails closed with "NO EVIDENCE"** when `"metrics"` is empty. That non-zero exit means *no numbers yet*, not *regression*.

## 4. Report honestly

State the lanes run, the test counts, and the lanes **not** run and why. If something failed, quote the failure. If a lane was skipped because it is slow, say that — do not let silence imply coverage.

Never report a speed change without a number from `make test-performance`. The straggler benchmark in `Tests/Performance/TransferThroughputTests.swift` compares coarse vs fine tiling under identical conditions and prints its ratio; that ratio is the evidence.
