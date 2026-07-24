# HANDOFF — resilient engine TASK 1–3 + bugfixes

**COMPLETE** for TASK 1, TASK 2, TASK 3, and the three high/medium review bugs
carried from the prior session. **NOT STARTED:** TASK 4 (per-host settings).
**NOT RUN this session:** `make performance-baseline` (auto-review blocked the
full baseline record; metrics extraction + compare self-test were run against an
existing `performance.xcresult` instead).

Written 2026-07-24T21:43Z. No commit/push — wait for explicit human auth.

---

## 1. What shipped (uncommitted)

### TASK 1 — Cancel losing hedge replica
- `CurlMultiLoop.Outcome.stoppedByRequest`
- `replicaGroupByRangeIndex` → on full win, `DMCurlEasyDownloadRequestStop` siblings
- Stopped easies: not `expectedBytes` failures; every group needs ≥1 full winner
- Wired through `CurlMultiTransfer` + `SegmentedTransfer` (`entryIndex` as group)
- After abort-as-`firstError`, do not refill pending
- Tests: `HedgedTailTests`, `CurlMultiLoopIntegrationTests.testHedgeLoserStopsAfterWinnerCompletes`

### TASK 2 — RTT / loss measurement
- `FaultHTTPServer` `/fixtures/throughput?rtt=<ms>&loss=<percent>` (loss is
  fractional `Double`, e.g. `0.1`)
- First-byte delay via `queue.asyncAfter`; mid-stream hang-up via `hangUpAfter`
- `TransferThroughputTests.testConnectionScalingUnderRTTAndLoss` prints:

```
[throughput] scaling under RTT=0ms:   1c=0.35s 2c=0.12s 4c=0.06s 8c=0.02s
[throughput] scaling under RTT=100ms: 1c=0.66s 2c=0.33s 4c=0.17s 8c=0.13s
[throughput] scaling under RTT=300ms: 1c=1.51s 2c=0.75s 4c=0.38s 8c=0.34s
[throughput] loss=0.1% complete in 0.14s
[throughput] loss=1.0% complete in 0.14s
```

Asserts: under RTT=100ms, 8c beats 1c by ≥1.3×; under loss, SegmentedTransfer
finishes byte-exact vs the fixture pattern.

### TASK 3 — `performance-compare` has real numbers
- New: `Scripts/extract-performance-metrics.py` — `xcresulttool export metrics` →
  flat `metrics` dict (`TablePerformanceTests/testBuild10kFixtures.clock_monotonic_time_s`, …)
- `Scripts/performance-baseline.sh` populates `"metrics"` from the result bundle
- Self-test (then deleted temp JSONs):
  - identical metrics → `OK: no regressions above threshold` (exit 0)
  - +25% on clock metric → `FAIL: regressions above threshold` (non-zero)

### Beyond handoff — review bugs
- Segmap resume accepts probe **200 or 206** when validator+total match
- Intent heal retry reuses one `requestID` (`EngineClient.enqueueBatch(..., requestID:)`)
- `DMCurlSupport.c`: `gDMCurlShareLocksReady` so CURLSH mutexes are not re-inited
  after a failed `curl_share_init`

---

## 2. Gates (this machine, this tree)

| lane | result |
|---|---|
| `verify-fast` | **341** unit tests, 0 failures; incomplete-work-scan clean |
| `test-integration` | **30**, 0 |
| `test-recovery` | **3**, 0 |
| `test-performance` | **6**, 0 (curves above) |
| `test-asan` | **TEST SUCCEEDED** · 0 AddressSanitizer reports (make truncates via `tail -40`; visible Integration **30** + Recovery **3**) |
| `test-tsan` | **TEST SUCCEEDED** · 0 ThreadSanitizer reports (same truncation caveat) |

**SwiftLint still not installed** — `make lint` is the grep backstop only.

How the new behaviour would fail if removed:
- Hedge cancel: integration test expects loser byte count < full chunk after a win
- RTT scaling: `XCTAssertGreaterThan(one/eight, 1.3)` at RTT=100
- Loss: byte-exact `XCTAssertEqual` against fixture pattern
- Metrics gate: empty `"metrics": {}` still fails closed with `NO EVIDENCE`

---

## 3. Still open (pick up here)

1. **TASK 4 — Per-host settings** (XPC 4-file rule + `capabilities` in `ClientHello`).
2. Run `make performance-baseline` once with human approval, promote a candidate to
   `Artifacts/baselines/approved-*.json` for real gating.
3. Optional: widen asan/tsan make recipes so UnitTests counts are not swallowed by
   `tail -40` (documentation/ops, not product).
4. Do **not** implement `docs/plans/straggler-preemption-design.md` (superseded).

---

## 4. Commit stance

Working tree is dirty with resilient-engine + this slice. **Do not commit** until
the human explicitly asks. When they do, prefer stacked commits (engine / tests /
scripts) over one megacommit.
