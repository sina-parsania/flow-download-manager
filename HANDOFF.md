# HANDOFF — Flow transfer engine

Written for the next agent. Assume you know nothing about the session that produced
this. **Read this file completely before touching anything.** Read `CLAUDE.md` next,
then `.claude/rules/transfer-hot-path.md` if you touch the engine.

Everything here is verified — commands were run, output was read. Where something
is unverified, it says so explicitly. Keep that habit.

---

## 0. How to work in this repo (read this even if you skip everything else)

These are not style preferences. Every one of them comes from a real failure in the
work that produced this file.

**1. `make verify-fast` is NOT the gate.** It runs format-check, lint, a Debug build,
**unit tests only**, and a banned-token scan. It does not run integration, recovery,
performance, or the sanitizers. A previous slice shipped "green on verify-fast" while
two segmented-transfer integration tests were failing. Use the lane table in §3.

**2. When a test fails, get the actual error. Do not hypothesise.** In this session I
burned four rounds guessing why a test failed (bad JSON escaping? decoder bug?) when
one grep of the log would have shown it. The failure was neither guess — it was a
cached `NSURL` size read. Run the lane, grep the log for `error:`, read the line.

**3. Trust the code, not the comments.** Comments in this repo have been actively
wrong: a helper documented as "cheap" ran a full `NSKeyedArchiver` pass on every
poll; a function promised "siblings run to completion" long after a refactor made it
tear them down. If a comment is load-bearing for your decision, verify it. If you
change behaviour, the comment is part of the change.

**4. A test that cannot fail is worth nothing.** The corruption bug in §4 was found
only because the test filled a partial with `0xFF` — a byte absent from the fixture.
Filled with zeroes, the test would have passed and the bug would have shipped. Always
ask: *what would this test do if the feature were broken?*

**5. Never hand-escape JSON in tests.** Use `JSONSerialization`. An ETag contains
quotes; a mis-escaped map makes `SegmentLedger.load` return **nil**, which the caller
treats as "no resume info" and silently starts over — so the test passes or fails for
entirely the wrong reason.

**6. Let SwiftFormat fix formatting.** Do not guess its rules. Run
`swiftformat --config .swiftformat <file>` and move on. Lint runs before build, so a
one-character mistake fails the whole gate.

**7. Run only one `xcodebuild` at a time.** Concurrent lanes collide on
`Artifacts/validation/latest/unit-tests.xcresult`. If you see
`Existing file at -resultBundlePath`, `rm -rf` it and re-run.

**8. Never commit, push, or publish without explicit human authorization**, per
`AGENTS.md`. Prepare the change, show it, wait. This includes `git add`.

**9. When you change a contract, fix the test that pinned it — and say why in the
test.** Do not delete it. A test failing because behaviour intentionally changed is
information, and the next reader needs the reason.

**10. Report honestly.** If a lane was not run, say so. If SwiftLint did not run
(it does not on this machine — see §3), say so. Do not let silence imply coverage.

---

## 1. Where things stand

**Committed:** 12 commits, `26058a0` … `f2319d5`, on top of baseline `ccdacdc`.
These cover UX polish, Chrome native-messaging hardening, App Intents, the Homebrew
cask draft, doc corrections, `.claude/` rules, and the CURLSH header export.

**Uncommitted (15 files):** the resilient-engine work described in §4. All green,
nothing staged.

```
 M Sources/CCurl/DMCurlSupport.c
 M Sources/TestFaultService/FaultHTTPServer.swift
 M Sources/TransferCore/SegmentedTransfer.swift
 M Sources/TransferCore/TransferSession.swift
 M Sources/TransferCurlBridge/CurlMultiLoop.swift
 M Tests/Integration/CurlMultiLoopIntegrationTests.swift
 M Tests/Integration/SegmentedTransferIntegrationTests.swift
 M Tests/Performance/TransferThroughputTests.swift
?? Sources/TransferCore/ResourceValidator.swift
?? Tests/Integration/FlakyLinkIntegrationTests.swift
?? Tests/Unit/HedgedTailTests.swift
?? Tests/Unit/ResourceValidatorTests.swift
?? Tests/Unit/SegmentMapDecodingTests.swift
?? Tests/Unit/TransferBackoffTests.swift
?? docs/plans/resilient-engine-design.md
```

**Design docs:** `docs/plans/resilient-engine-design.md` is the current one and
matches what shipped. `docs/plans/straggler-preemption-design.md` is **superseded** —
it proposes preemption, which was rejected in favour of hedging. Do not implement it.

---

## 2. Verified numbers

Measured on this machine, this tree. Reproduce with `make test-performance`.

```
scaling under a per-connection cap:
  1c=2.65s(1.0x)  2c=1.11s(2.4x)  4c=0.54s(4.9x)  8c=0.25s(10.4x)  16c=0.11s(24.3x)

straggler tail: coarse=4.37s  fine=0.75s  speedup=5.85x
```

**Read these correctly.** The scaling curve is measured against a server that caps
*each connection* — the only condition where parallel connections multiply. On a link
where the client's own pipe is the bottleneck, the curve is flat. The straggler number
compares fine tiling against coarse tiling under an artificial slow connection; it is a
proof that the refill loop works, **not** a claim that downloads got 5.85× faster.

There is still **no end-to-end before/after product measurement.** Do not claim one.

---

## 3. Verification

```bash
make verify-fast        # format-check, lint, build-debug, unit tests, banned-token scan
make test-integration   # REQUIRED for TransferCore / TransferCurlBridge / CCurl / Persistence / EngineAgent
make test-recovery      # resume + crash boundaries
make test-performance   # REQUIRED if you touch tiling, concurrency bounds, or the refill loop
make test-asan          # REQUIRED for any C change or curl handle-lifetime change
make test-tsan          # REQUIRED for any concurrency or shared-state change
```

Current state, all six run, all green:

| lane | result |
|---|---|
| `verify-fast` | 340 tests, 0 failures |
| `test-integration` | 29, 0 |
| `test-recovery` | 3, 0 |
| `test-performance` | 5, 0 |
| `test-asan` | 3, 0 · 0 sanitizer reports |
| `test-tsan` | 3, 0 · 0 sanitizer reports |

**SwiftLint has never run on any of this work.** `make lint` prints
`lint: swiftlint not installed; using grep safety backstop` **and passes anyway**. A
green `make lint` here means nothing. Install it (`make bootstrap-tools`) or state
plainly in your report that the strict rule set did not run.

Single test:

```bash
xcodebuild -project DownloadManager.xcodeproj -scheme DownloadManager \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/DerivedData \
  -only-testing:IntegrationTests/FlakyLinkIntegrationTests test
```

`DownloadManager.xcodeproj` is generated and gitignored. After editing `project.yml`,
run `make project`.

---

## 4. What the uncommitted work does, and why (do not undo this)

### 4.1 Validator-bound segment map — a silent corruption fix

`Sources/TransferCore/ResourceValidator.swift` (new), wired into `SegmentedTransfer`.

The `.segmap` used to record only `total`, and resume accepted a partial when the byte
count matched. **A resource that changed but kept its length was resumed into**, so the
finished file was old bytes stitched to new ones — exactly the right size, passing every
later check, and garbage. On a link that drops often, resumes are the normal case, so
this was the most likely corruption path in the engine.

Rules the comparison follows, in order: strong ETag → `Last-Modified` → length.
A **missing** signal is never an error (many servers send none, and maps written by
older builds have none). Only a **contradicted** signal rejects a resume. Weak ETags
(`W/`) are deliberately ignored: they promise semantic equivalence, not byte equality,
and stitching two halves needs byte equality.

### 4.2 Cached-size bug — every wipe path was broken

`URL.resourceValues(forKeys:)` bridges to `NSURL`, **which caches**. The resume path
read the partial's size, wiped the file, then read the size again from the same `URL`
value — and got the stale pre-wipe number. So `existing > 0`, execution fell into the
legacy contiguous-prefix branch, and threw `incompleteWrite` instead of downloading
fresh. Every wipe — length mismatch, size mismatch, and now validator mismatch — failed
the job instead of restarting it.

Fixed with `SegmentedTransfer.fileSize(at:)`, which uses `FileManager` and does not
cache. **Do not reintroduce `resourceValues` for file sizes anywhere in this path.**

### 4.3 Retry budget spent on stalls, not errors

Was: `maxAttempts = 3` for the **entire job**. Three blips across a multi-gigabyte
download and it failed permanently — unusable on a link that hiccups.

Now: a pass that moved bytes resets the counter, however many individual ranges
dropped. Only consecutive zero-progress passes count, budget 10.

### 4.4 Backoff with full jitter

Was linear (`Thread.sleep(Double(attempt))`) and unjittered, so 32 segments that
dropped on the same blip retried at the same instant and recreated the burst.
Now `random(0 ..< min(30s, 500ms · 2^n))`. Full jitter, not equal jitter — spreading a
synchronised herd is the entire point.

### 4.5 Refill survives single-range failures

This **reverses a decision made earlier in this repo.** Stopping the pending queue on
the first error is right for a clean link and wrong for a bad one, where the common
case is one range dropping while thirty are healthy. `CurlMultiLoopIntegrationTests
.testFailedRangeStillSurfacesWhileOtherRangesKeepRunning` pins the new contract and
explains the reversal.

### 4.6 Socket tuning

`LOW_SPEED_TIME` 30s → 10s, `CONNECTTIMEOUT` 15s → 8s, `TCP_KEEPALIVE` on
(idle 30s, interval 15s). NAT silently drops idle mappings; without keepalive curl
waits on a connection the peer forgot. Dead-slot recovery ~45s → ~10s.

### 4.7 Concurrency: start at ceiling, back off, recover

**Read this before touching it — I got it wrong once.** I first implemented classic
AIMD starting at 8 and increasing per clean pass. That was a straight regression: a
healthy download is a **single pass**, so the increase never fires, and every clean
transfer was capped at 8 instead of up to 32.

Correct behaviour, now in place: start at the caller's ceiling, halve on a stall
(floor 2), and regain one connection per clean pass. Additive increase only matters
for a link recovering from stalls — which is exactly when multiple passes happen.

### 4.8 Hedged tail

When `remaining.count < connectionLimit`, slots are idle by definition. `hedged()`
adds duplicate work for the largest remaining chunks so a second connection races the
same byte range. The slow connection is never killed and keeps contributing.

Safe because a replica writes the same bytes at the same offsets of a resource whose
identity the validator pinned (duplicate `pwrite` is idempotent), and
`SegmentLedger.record` keeps a monotonic `max()` per entry so double reporting cannot
inflate progress. Capped at 2 hedges, chunks ≥1 MiB only.

---

## 5. Incomplete work — pick up here

Ordered. Do them in order; each is scoped to be finishable and verifiable on its own.

### TASK 1 — Cancel the losing hedge replica (small, well-defined, start here)

**Why:** without a cancel, the losing replica downloads its whole chunk. Wasted
bandwidth is bounded (2 hedges × chunk size) but real, and it matters on metered
connections.

**The C side already exists and is fully implemented but has no Swift caller:**

- `DMCurlEasyDownloadRequestStop(DMCurlEasyDownload *)` — `DMCurlSupport.c:642`
- `stopRequested` on the write context, checked in the write callback (`:302`, `:308`)
- `DMCurlFillDownloadResult` reports it as `stoppedByRequest = 1` with
  `code = CURLE_OK` (`:555`) — a stop is **success with a short read**, never a cancel
- `int stoppedByRequest` on `DMCurlDownloadResult` — `DMCurlSupport.h:28`

Verify that with `grep -n "RequestStop\|stoppedByRequest" Sources/CCurl/DMCurlSupport.c`
before you start. **You should not need to modify any C.**

**Steps:**
1. In `CurlMultiLoop.downloadRangesToFile`, track which range index each live easy is
   serving (`easyIndexByPointer` already does this).
2. When a range completes, if another live easy is serving the **same** ledger entry,
   call `DMCurlEasyDownloadRequestStop` on it.
   - You will need the caller to tell `CurlMultiLoop` which ranges are replicas of
     each other. `SegmentedTransfer.hedged()` knows: replicas are appended after the
     originals and share an `entryIndex`. Pass a `replicaGroups: [Int: Int]` (range
     index → group id) or equivalent. Keep it explicit; do not infer from byte ranges.
3. In `finishEasy`, a result with `stoppedByRequest` must **not** be an error and must
   **not** fail the `expectedBytes` check — a short read is expected there.
4. A stopped replica must not be counted in the final
   `outcomes.count == ranges.count` guard.

**Acceptance:** extend `Tests/Unit/HedgedTailTests.swift` and add an integration test
proving (a) the file content is still byte-exact, (b) the losing replica transferred
fewer bytes than the full chunk.

**Gate:** `verify-fast` + `test-integration` + `test-asan` + `test-tsan`.

**Stop and ask if:** you find yourself needing to change the meaning of the job-wide
`abortFlag`. A stop must never be reportable as a user cancellation — that is the
whole reason the separate flag exists.

### TASK 2 — Measure what a bad link actually costs (highest value for users)

**Why:** every number in §2 was measured on loopback with no RTT and no packet loss.
The scenario that matters most for users on weak networks — high RTT plus loss, where a
single TCP flow is limited to roughly `MSS / (RTT · √p)` regardless of bandwidth — has
**never been measured here**. This is where multi-connection genuinely multiplies, and
we cannot currently prove our own behaviour.

**Steps:**
1. Extend `FaultHTTPServer` with per-connection latency and drop injection —
   `?rtt=<ms>&loss=<percent>` alongside the existing `kbps`. Follow the shape of
   `serveThroughput` / `serveFlaky` in `Sources/TestFaultService/FaultHTTPServer.swift`.
2. Add benchmarks to `Tests/Performance/TransferThroughputTests.swift`: the connection
   scaling curve at RTT 0 / 100 / 300 ms, and with 0.1% / 1% loss.
3. Print the curve the way the existing tests do (`print("[throughput] …")`) so results
   are visible in the lane output.

**Acceptance:** the curve is printed and the numbers are stable across runs. Assert
*relationships* (more connections beat fewer under a cap), never wall-clock constants —
those break on a different machine.

**Do not** claim a product speedup from these. They measure the mechanism.

### TASK 3 — Make `performance-compare` a real gate

**Why:** `Scripts/performance-baseline.sh` always writes `"metrics": {}`, so
`make performance-compare` has nothing to compare and **fails closed** with
`NO EVIDENCE`. That is correct behaviour (better than a false OK) but it means there is
no regression gate on performance at all.

**Steps:** extract numeric metrics from the XCTest result bundle
(`Artifacts/validation/latest/performance.xcresult`, via `xcrun xcresulttool`) into the
`metrics` object. Then `performance-compare` starts doing its job.

**Acceptance:** record a baseline, deliberately slow something down, confirm the
comparator fails.

### TASK 4 — Per-host settings

**Why:** the main competitor keys connection count, speed limit, user-agent and
credentials by **domain**. Many servers rate-limit or ban at 8+ connections, and today
the user's only lever is global. `HostObservationRepository` already exists and stores
per-host hints — this extends it to user-controlled settings.

Follow `.claude/rules/xpc-boundary.md`: an RPC change touches **four** files, and the
`capabilities` array in `ClientHello` must be updated or the handshake gate breaks.

### TASK 5 — Deferred surfaces (ADR-bounded; closed for community path)

These are **not** unfinished product stubs. ADRs and packaging reality bound them:

- **Torrent / magnet** — ADR 0006: Compose can **inspect** `.torrent` metadata;
  magnets stay unsupported; libtorrent download remains deferred until a
  VendorBuild pin lands.
- **Media / yt-dlp** — optional VendorBuild helper; Compose can probe page URLs
  when `yt-dlp` is present and explains when it is missing. No fake download.
- **Notarization / signing** — ADR 0008 Track B: `make release-codesign` /
  `make release-notarize` fail closed without credentials. Community default
  stays unsigned DMG.
- **Safari Web Extension** — `BrowserExtension/safari/README.md`; unsigned Safari
  cannot ship to end users. Chrome companion remains the browser path.
- **`docs/plans/straggler-preemption-design.md`** — **SUPERSEDED** by hedged tail
  in `resilient-engine-design.md`. Do not implement preemption from that doc.

---

## 6. Known traps in this repo

- **The private spec pack is gitignored.** Source comments and ADRs cite
  `00-master-plan.md`, `04-domain-and-data-contracts.md`, `08-validation-commands.md`
  and others. **You cannot read them.** Do not hunt for them; work from `AGENTS.md`,
  `Documentation/adr/`, and the code.
- **`CURLMOPT_PIPELINING = CURLPIPE_NOTHING` is load-bearing.** Without it, HTTP/2
  folds every segment onto one TCP connection and one congestion window, and
  segmentation buys exactly nothing.
- **Durability is owned by Swift** — one `fsync` after the map loop. Do not put
  per-easy `fsync` back in the C shim; with 32 segments sharing one fd that was 32
  redundant full-file syncs.
- **Never mutate the multi handle while iterating `curl_multi_info_read`.** Collect the
  `CURLMSG_DONE` messages first, then finish and refill.
- **Release a progress box only after `DMCurlEasyDownloadFinish`** destroys the easy
  that holds its `passUnretained` pointer.
- **`/fixtures/ok` is 4 KiB**, and `preferredSegmentCount` always tiles it to **1**. It
  cannot test segmentation. Use `/fixtures/large` (2 MiB), `/fixtures/throughput`
  (rate-capped), or `/fixtures/flaky` (drops connections).
- **The UI never owns sockets, partial files, or the database.** `DownloadEngineAgent`
  is the sole writer. If a change makes `Presentation` touch any of those, it is the
  wrong change — add an RPC.

---

## 7. Definition of done for whatever you pick up

1. All six lanes in §3 green, with the test counts quoted in your report.
2. Every new behaviour has a test that **fails if the behaviour is removed**. State how
   you confirmed that.
3. No `TODO`/`FIXME`/placeholder — `make incomplete-work-scan` stays clean.
4. Comments you invalidated are updated in the same change.
5. A handoff at `Artifacts/handoffs/<slice>-<UTC>.md`, led by
   `COMPLETE | INCOMPLETE | BLOCKED`, with raw command output, and stating what you did
   **not** do as explicitly as what you did.
6. Nothing committed or staged without explicit human authorization.
