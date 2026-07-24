# Straggler preemption — design

Status: **SUPERSEDED**

Superseded by [`resilient-engine-design.md`](resilient-engine-design.md)
(hedged tail + cancel losing replica). Do **not** implement connection
preemption from this document.

The hedging approach keeps the slow connection contributing bytes and races a
duplicate range on an idle slot instead of killing the straggler mid-Range.
That matches libcurl’s fixed `Range: start-end` model without inventing a
server-side early stop.

Historical note: an earlier draft below proposed stopping the straggler and
re-tiling its remainder. That was rejected in favour of hedging; the C
`DMCurlEasyDownloadRequestStop` path is now used to cancel the *losing hedge
replica*, not to preempt a healthy primary.

---

# Historical draft (do not implement)

Status was: `DESIGN — implementing`
Supersedes the "safe-zone tail steal" item deferred in
`docs/plans/v0.3-speed-ux-deletion-plan.md`.

## The problem

Fine tiling bounds what a slow connection *costs* (it holds one ~4 MiB chunk),
but it cannot take back work already assigned. Once `pending` is empty, every
remaining chunk is owned by a live connection and the job finishes at the pace of
the slowest one. Measured today: the straggler benchmark still shows the tail is
the last thing to finish.

## What we are NOT doing, and why

AB Download Manager splits the *tail* off a running part without dropping its
socket, guarded by a 1 MiB safe zone. That works because their part downloader
issues its own reads and can simply stop early.

Flow hands libcurl a fixed `Range: start-end`. **There is no way to tell an HTTP
server to stop mid-range without closing the connection.** So the equivalent here
is: stop the straggler, keep the bytes it already wrote, and re-tile its
remainder across fresh connections. The cost is one re-established connection —
paid only when a connection is already demonstrably slow.

## The corruption risk was overstated

`DMCurlFillDownloadResult` sets `out->bytesWritten = writeCtx->written` at finish,
whatever ended the transfer. That is the authoritative count of bytes actually
`pwrite`n. Because we only compute the remainder *after* the easy has finished,
there is no in-flight byte to race and no safe zone needed. The `.segmap` is
updated from a number curl gives us, not one we guess.

## Design

### 1. C — stop one easy without failing the job (`DMCurlSupport.c`)

`DMCurlWriteCtx` gains `volatile int32_t stopRequested`. The write callback
treats it like the abort flag and returns 0, but `DMCurlFillDownloadResult`
distinguishes the two:

- job abort → `CURLE_ABORTED_BY_CALLBACK` (unchanged, an error)
- stop request → `out->stoppedByRequest = 1`, `out->code = CURLE_OK`

New: `void DMCurlEasyDownloadRequestStop(DMCurlEasyDownload *)`, and
`int stoppedByRequest` on `DMCurlDownloadResult`.

The job-wide `abortFlag` is untouched — a stop must never look like a cancel.

### 2. `CurlMultiLoop` — detect and preempt

Per pass, track each live segment's bytes and the wall-clock when it started.
When **all** of these hold, request a stop on the worst segment:

- `pending` is empty (nothing cheaper to hand out)
- ≥2 segments live (stopping the only one accomplishes nothing)
- its throughput is < ¼ of the best live segment's
- its unwritten remainder ≥ 2 × 4 MiB (below that, re-tiling cannot pay for a
  new connection)
- fewer than `maxPreemptions` (4) stops so far this pass — a thrash guard

A stopped segment reports through a new `stoppedSegments: Set<Int>` on the
outcome, and is **not** an error: `finishEasy` skips the `expectedBytes`
check for it, and the final `outcomes.count == ranges.count` guard becomes
`outcomes.count + stopped.count == ranges.count`.

### 3. `SegmentedTransfer` — re-tile the remainder

`runSegmentedRanges` returns the stopped set. In `runMapLoop`:

- `markCompleted(entryIndices:)` **must exclude stopped indices** — marking a
  preempted chunk complete is the one way this design could corrupt a file, and
  it is the single most important line in the change.
- After a pass with stops, `ledger.resplit(targetCount:)` re-tiles what is left
  and the loop runs another pass. The existing `while true` in `runMapLoop`
  already does this; preemption just gives it something to do.
- A pass that only preempted must not count against `maxAttempts` — that counter
  is for failures.

## Failure modes and the tests that catch them

| risk | test |
|---|---|
| preempted chunk marked complete → truncated file | integration: preempt mid-transfer, assert final bytes == fixture |
| stop mistaken for a job cancel | integration: assert job completes, not `aborted` |
| short read treated as `incompleteWrite` | integration: assert no error surfaces |
| thrashing on a uniformly slow link | unit: policy returns no preemption when all segments are equally slow |
| preempting the only live segment | unit: policy declines below 2 live |
| remainder too small to be worth it | unit: policy declines below 2 × minChunk |

Plus the whole existing gate: recovery (resume matrix), ASan, TSan.

## Acceptance

The straggler benchmark gains a third comparison: fine tiling **with** preemption
must beat fine tiling **without** it, under the same straggler. If it does not,
the mechanism does not work and the change should not ship.
