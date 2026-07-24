# Resilient transfer engine — design

Status: `DESIGN — implementing`
Supersedes `docs/plans/straggler-preemption-design.md` (preemption was the wrong
primitive; see §6).

Target link: high RTT, jittery, packet loss, intermittent disconnects.
Priority order is **correctness → resilience → speed**. Never lose bytes, never
stitch a corrupt file, then go fast.

---

## 1. Validator-bound segment map (correctness — highest value)

**Today the `.segmap` records `total`, `baseOffset`, `entries` and nothing else.**
On resume, `SegmentedTransfer.downloadHTTP` re-probes and accepts the partial when
`totalLength(from: probe) == ledger.total`. Length is the only check.

So: a resource that changes between sessions but keeps its byte count is resumed
into. The already-downloaded ranges come from the old file, the rest from the new
one, and the result is a file that is the right size, passes every internal check,
and is garbage. On a link that disconnects often — i.e. many resumes — this is the
most likely way Flow corrupts data.

**Change.** `SegmentLedger.MapFile` gains `etag` and `lastModified`, captured from
the probe that created it. On resume:

- both sides have an ETag and they differ → resource changed → discard partial,
  restart clean
- ETags match → resume (strongest signal, done)
- no ETag either side → fall back to `Last-Modified` + `total`
- no validator at all → resume on `total` alone, as today, because refusing would
  break servers that send neither

A missing validator is not an error; a *contradicted* validator is.

Old `.segmap` files have no validator field — decode them with `nil` and treat as
the "no validator" case. Never fail a resume because the map predates this change.

## 2. Per-segment retry, not per-job

`runMapLoop` today: `maxAttempts = 3` for the entire job. Three transient blips
across a multi-gigabyte download and the job is permanently failed — on a link
that drops every few minutes, that is unusable.

**Change.** Attempts move to the segment. Each ledger entry carries its own
attempt count with a much larger budget (10). The job-level counter only counts
passes that made *zero* progress — a pass that moved bytes is not a failed attempt
no matter how many individual ranges hiccuped.

This also reverses a decision I made earlier in this repo: "first error stops
refilling the pending queue". That is correct on a clean link (fail fast, don't
pile on) and wrong here — on a flaky link the common case is one range dropping
while thirty are healthy. Refilling continues; the failed range is re-queued with
backoff.

## 3. Backoff with full jitter

`Thread.sleep(forTimeInterval: Double(attempt))` is linear, unjittered, and blocks
the pass. With 32 segments hitting a blip together they all retry at the same
instant and re-create the burst that killed them.

**Change.** Per-segment, non-blocking, full jitter:

```
delay = random(0 ..< min(30s, 500ms * 2^attempt))
```

Full jitter (not "equal jitter") because the goal is spreading a synchronised
herd, and it is the variant that minimises contention.

## 4. Fail fast, reconnect fast

Current settings hold a dead connection far too long on a lossy link:

| option | now | new | why |
|---|---|---|---|
| `CURLOPT_LOW_SPEED_TIME` | 30 s | 10 s | a stalled slot is a lost slot |
| `CURLOPT_CONNECTTIMEOUT_MS` | 15 s | 8 s | prefer another attempt over one long wait |
| `CURLOPT_TCP_KEEPALIVE` | unset | 1, idle 30 s, interval 15 s | NAT silently drops idle conns; without keepalive curl waits for a timeout that never comes |

Worst-case recovery of a dead segment goes from ~45 s to ~10 s.

## 5. AIMD concurrency

Segment count is chosen from file size and clamped by the socket budget — it never
reacts to the link. On a lossy path 32 connections compete with each other and
with the retransmits, and throughput *drops* as concurrency rises.

**Change.** Additive-increase / multiplicative-decrease, inside the existing socket
reservation:

- start at `min(8, budget)`
- a pass that completes with no segment errors → `+1`
- any segment error → `max(2, live / 2)`

Bounded below by 2 so a bad patch cannot collapse to single-stream, and above by
the host/socket budget that already exists. This is congestion control, and the
same reason TCP uses it applies here.

## 6. Hedged tail (speed)

Earlier plan was to *preempt* a straggler: stop it and re-tile its remainder. That
throws away in-flight progress and pays a reconnect — on a high-RTT link the
reconnect alone can cost more than the straggler.

**Hedging is strictly better.** At the tail, `remaining.count < connectionLimit`,
so connection slots are already idle. Spend an idle slot on a *second* connection
for the same byte range and let them race:

- the slow connection is never killed and keeps contributing
- duplicate `pwrite` of the same range from the same validated resource is
  byte-identical, so it is idempotent
- `SegmentLedger.record` is already a monotonic `max()`, so it dedupes for free
- on a flaky link the replica doubles as redundancy: if one peer drops, the other
  carries on

Policy: only when slots are idle, only for chunks with ≥1 MiB unwritten, at most 2
replicas per chunk and 4 hedges per pass, largest-remaining first.

The loser is cancelled once the winner completes the range — that needs a small
per-easy stop in the C shim (`stopRequested` on the write context, reported as
`stoppedByRequest` with `CURLE_OK`, never as a cancel). Without cancellation the
duplicate would download the whole chunk twice; with it the waste is the bytes
already in flight.

---

## Failure modes and their tests

| risk | test |
|---|---|
| resumed into a changed resource | integration: serve `/fixtures/changing-etag`, resume, assert restart not stitch |
| old `.segmap` without validator rejected | unit: decode a v1 map, assert resume still allowed |
| flaky link exhausts job attempts | integration: fault server drops N times, assert completion |
| retry herd | unit: backoff draws are spread, never all equal |
| hedge writes corrupt the file | integration: force a hedge, assert bytes == fixture |
| preempted/stopped chunk marked complete | integration: assert final size and content |
| AIMD collapses to 1 | unit: floor holds at 2 under repeated errors |

Plus the standing gate: `verify-fast`, integration, recovery, performance, ASan, TSan.

## Acceptance

1. Straggler benchmark: hedged tail beats non-hedged under the same straggler.
2. New flaky-link benchmark: a fixture that drops connections mid-transfer
   completes, with content identical to the fixture, and does so in bounded time.
3. Resume matrix stays green.
