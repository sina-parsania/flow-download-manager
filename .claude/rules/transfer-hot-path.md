---
paths:
  - "Sources/TransferCore/**"
  - "Sources/TransferCurlBridge/**"
  - "Sources/CCurl/**"
  - "Sources/EngineAgent/TransferOrchestrator.swift"
  - "Tests/Integration/**"
  - "Tests/Performance/**"
---

# Transfer hot path — invariants

You are in the code that moves bytes. Everything here has cost real debugging time at least once.

## Gate (non-negotiable)

`make verify-fast` does **not** cover this code. Before reporting done:

```bash
make test-integration
make test-recovery
make test-asan     # any C change, or any change to curl handle lifetime
make test-tsan     # any change to shared state or concurrency
make test-performance   # any change to tiling, concurrency bounds, or the refill loop
```

A slice once shipped "green on verify-fast" with two segmented-transfer integration tests failing. Do not repeat it.

## Resume correctness beats throughput, always

- **`.segmap` is the authority.** Once a partial is preallocated with `ftruncate`, its file size is meaningless — only the segment map knows which ranges are real.
- **A probe failure must never wipe a partial.** Network down at relaunch, a 5xx, a 429 — all transient. Propagate the error so the retry/requeue path keeps the bytes. Only wipe when the remote length is *known* and *clearly different*.
- Never treat "file size >= expected" as proof of completion. Preallocated segmented shells have full size with empty ranges.

## libcurl invariants

- **`CURLMOPT_PIPELINING = CURLPIPE_NOTHING` is load-bearing.** Without it, HTTP/2 servers multiplex every segment onto one TCP connection and one congestion window, and segmentation buys exactly nothing.
- **Durability lives in Swift** — one `fsync` after the map loop / single-stream finish. Per-easy `fsync` in the C shim meant 32 redundant full-file syncs on one shared fd. Don't put it back.
- **Do not mutate the multi handle while iterating `curl_multi_info_read`.** Collect the `CURLMSG_DONE` messages first, then finish and refill. Adding a handle mid-iteration is not a documented-safe contract.
- **Release a progress box only after `DMCurlEasyDownloadFinish`** destroys the easy that holds its `passUnretained` pointer. Freeing earlier is a use-after-free waiting for a scheduling change.
- The shared `CURLSH` deliberately shares **DNS + SSL session only**. Sharing `CURL_LOCK_DATA_CONNECT` serializes handle setup across threads, which is the opposite of what segmented transfers want.

## Tiling and the refill loop

The ledger tiles finer (≤128 chunks) than `maxConcurrent` bounds concurrency. **That gap is the mechanism**, not an accident: when a connection frees up it pulls the next tile, so a slow connection only ever holds one small tile instead of a full `1/N` share.

Measured, `Tests/Performance/TransferThroughputTests.swift`: coarse 4.37 s → fine 0.75 s, **5.83×**.

If you change tiling, `maxConcurrent`, or the drain loop, that benchmark is your acceptance test.

## A range failure must not kill healthy siblings

Record the first error, stop refilling from the pending queue, let in-flight easies drain, *then* throw. Tearing down 31 healthy connections because one range 503'd makes flaky links dramatically worse — and burns one of only three whole-job attempts.

## Any concurrency bound must be honoured on every path

`maxConcurrent` exists to respect the orchestrator's socket reservation (32/host, 96 total). The Dispatch fallback in `runSegmentedRanges` once accepted the parameter and ignored it — with 128-chunk tiling that would have opened 128 sockets to a single host.

## Benchmarks that cannot fail are worthless

`/fixtures/ok` is **4 KiB** and `preferredSegmentCount` always tiles it to **1**. Use `/fixtures/large` (2 MiB) for multi-segment behaviour and `/fixtures/throughput` (rate-capped) for anything timed. An uncapped loopback transfer finishes instantly and makes parallelism invisible.

Prefer a benchmark that compares two configurations under identical conditions (coarse vs fine tiling under the same straggler) over one that asserts a wall-clock number — the former breaks when the mechanism breaks; the latter breaks when the machine changes.
