# Handoff — download engine review, passes 1–2 — 2026-08-01T2330Z

## Outcome

**INCOMPLETE** — two passes of a running review. One real bug found and fixed, three
repo beliefs tested (one wrong and corrected, one wrong and removed, one confirmed), and
one of my own earlier findings retracted. `TransferOrchestrator`, the XPC boundary,
`Persistence`, and an architecture pass are **not yet reviewed**.

Builds on `197849a` plus the uncommitted signed-URL-resume slice. Nothing committed.

## Gate — after every change below

| lane | result |
| --- | --- |
| `make verify-fast` | 544 unit tests, 0 failures · incomplete-work-scan clean |
| `make test-integration` | 70, 0 |
| `make test-recovery` | 10, 0 |
| `make test-performance` | 6, 0 |
| `make test-asan` | 0 sanitizer reports (C changed) |
| `make test-tsan` | 0 sanitizer reports |

## Bug — `resplit` silently destroyed the resume it exists to protect

`SegmentLedger.resplit` split an entry and **appended** the tail half to the end of the
array. `load` rejects any map whose entries are not contiguous and ascending, and also
requires `last.end == total - 1` — splitting a *middle* entry breaks both.

The failure is invisible at the time: the in-memory map is still correct, so the pass
finishes normally. The damage appears on the **next launch** — `load` returns nil, the
resume is skipped, and a preallocated full-size partial is left behind for the caller to
misread. Splitting the *last* entry happened to be safe, which is how it survived.

Reachable exactly where it hurts: `resplit` is called from `runMapLoop`'s stall recovery,
i.e. on the flaky link that resume exists for.

Fix: `entries.insert(…, at: largest + 1)`. Two unit tests in
`Tests/Unit/SegmentResplitTests.swift`, verified red first.

## Three repo beliefs, tested rather than quoted

**1. `SO_RCVBUF = 2 MiB` "enlarged" the receive buffer — it shrank it. REMOVED.**
Setting `SO_RCVBUF` clears `SB_AUTOSIZE`, so the kernel stops growing the buffer, and the
window scale is then derived from the app's value instead of `net.inet.tcp.autorcvbufmax`.
Verified on this machine:

```text
net.inet.tcp.doautorcvbuf: 1
net.inet.tcp.autorcvbufmax: 4194304      ← 4 MiB, twice what the call asked for
net.inet.tcp.recvspace:    131072
kern.ipc.maxsockbuf:       8388608
```

Window scale is negotiated in the SYN and cannot grow later, so every connection was
pinned to the smaller ceiling for its whole life.

**Measured impact of removing it: none.** At ~1.7 MB/s per connection over 127 ms the
window in use is ~220 KB, far below either ceiling — this path is loss-limited, not
window-limited. Removed because it was a real ceiling downgrade on a false premise, not
because it bought throughput. Two alternating runs each: 13.65/13.86 with, 13.82/13.39
without.

**2. `CURLOPT_BUFFERSIZE = 1 MiB` does not size the write callback. CONFIRMED at runtime.**
Instrumented the write callback: **max chunk 16384** over 14 000 calls, i.e.
`CURL_MAX_WRITE_SIZE` (`curl.h:265`) regardless of `BUFFERSIZE`. Comment added so nobody
reasons from the wrong number again. It also settles a performance question — see below.

**3. `NET_SERVICE_TYPE_RD` as a priority hack — premise is wrong, call KEPT.**
Apple's `sys/socket.h` says service types "do not represent priorities", that classes with
lower delay tolerance get **smaller** queues, and explicitly warns against using a class
that does not match the traffic. `BK` is the documented class for bulk transfer; `RD` is
for email and IM. The old comment ("high-priority interactive bulk transfers … IDM-style
priority") was both self-contradictory and the exact reasoning Apple warns against.

The comment is fixed; **the call is kept** because the A/B could not separate it from the
alternatives — see the failed measurement below. Changing it on documentation alone would
be speculation in the opposite direction.

## A measurement that failed, reported as such

Removing the whole sockopt callback (kernel defaults: BE + autotuned buffer), 7 runs each,
alternating:

```text
current  : 13.65 13.86  4.69  5.10 14.00 12.22 13.27   median 13.27
nosockopt: 13.82 13.39  5.44 13.99 11.97 11.80 13.80   median 11.97
```

The same binary produced 5.44 and 13.99 back to back. Link conditions swung ~3×, which is
larger than any difference between variants, and the median slightly favours the current
code. **Inconclusive — no claim either way.** A real answer needs a congested-link
measurement or a controlled path.

## Checked and cleared — not a problem

`SegmentLedger.record` runs an O(n) reduce over up to 1024 entries on every write callback,
which looked like a hot-path cost. With the callback rate now **measured** (700/s) rather
than assumed, a 4 GiB file works out to ~750 K additions/s ≈ **0.07 % CPU**, and every
segment runs on the one multi-loop thread so the locks are uncontended. Not worth changing.

## Retracted from an earlier handoff

"No connection reuse — every easy opens a fresh TCP+TLS connection" was **wrong**.
Re-measured against a real keep-alive host: **144 easy handles, 29 TCP connections**.
The original measurement was taken under the HTTP 429 I had provoked, where error responses
close the connection; `FaultHTTPServer` also sends `Connection: close` on every response.
Neither source could have shown reuse. Corrected in `signed-url-resume-20260801T2230Z.md`.

## Connection-count data

Aggregate throughput, same host, average over the run (not the instantaneous sample):

| connections | MB/s |
| --- | --- |
| 4 | 5.03 |
| 8 | 7.27 |
| 16 | 7.51 |

4 → 8 is a clear win; 8 → 16 is nearly nothing on this host. The current
`defaultConnectionsPerJob = 8` is reasonable and raising it blindly is not indicated.
Single noisy samples — re-run before acting.

## Research

`Documentation/research/throughput-techniques.md` (1118 lines, primary sources cited to
curl 8.21.0, xnu, the macOS 26.5 SDK headers, and RFCs). Headline: the path is
**loss-limited**, so connection count is the dominant lever and most other tuning treats a
non-bottleneck. HTTP/3 is not compiled in and would not help — one QUIC connection is one
congestion controller. `CURLPIPE_NOTHING` is correct and must stay.

Its ranked suggestion I have **not** yet tested: lower the 4 MiB minimum tile (XDM's floor
is 256 KiB), which should shorten the straggler tail.

## Pass 3 — `TransferOrchestrator`

### Bug — a stalled transfer kept showing its last speed

The progress ticker fires every 250 ms but only did anything when bytes had arrived:

```swift
guard let self, let sample = liveBytes.take() else { continue }
```

`LiveByteCounter.take()` returns nil on a quiet interval, so on a stall the estimator was
never told time had passed and `speedBytesPerSecond` froze at whatever the transfer last
managed. A dead connection sits for `CURLOPT_LOW_SPEED_TIME` (10 s) before libcurl kills
it, and the map loop then backs off up to 30 s — tens of seconds of the UI reporting a
speed that is a lie, on exactly the lossy link where stalls are routine.

Fixed with `tickProgress`, which re-reports the same cumulative count on a quiet tick so
the estimator sees a zero-byte interval and decays. `recordProgress` already takes `max()`
of the byte count, so re-reporting cannot walk progress backwards.

`Tests/Unit/TransferSpeedDecayTests.swift` pins both halves: the estimate must fall to
<1 % after 24 s of no progress, and a single quiet tick must **not** halve it (0.78 prior
weight, so ordinary jitter between ticks does not read as a stall).

Seam note: the tests cover the estimator, which is a pure struct. The defect was in the
actor's ticker, and there is no seam to test that directly without a stalling fixture —
`/fixtures/flaky` drops the connection rather than going quiet. Recorded rather than faked.

### Finding, not fixed — `Retry-After` is documented but never honoured

`RetryPolicy` is titled "Jittered exponential backoff with **Retry-After** support
(FR-TRN-012)" and `delayNanoseconds(attempt:retryAfterSeconds:)` implements it. The single
call site passes `nil`:

```swift
let delay = retryPolicy.delayNanoseconds(attempt: attempt - 1, retryAfterSeconds: nil)
```

and grepping the whole tree finds no capture of the header at all — `DMCurlHeaderCtx`
collects content-type, etag, last-modified, accept-ranges, content-disposition and
content-range, but not retry-after. So the feature does not exist end to end, and the
comment claims it does.

It matters here: these hosts do return 429 (I triggered one myself), and the engine
currently answers on its own schedule rather than the server's — coming back too early
burns one of only 8 whole-job attempts.

Not fixed because it is a genuine slice, not a one-liner: capture in C → `DMCurlDownloadResult`
→ somewhere on `TransferError` (which today carries only `httpStatus(Int)`, so this ripples)
→ orchestrator. Recommended as the next piece of work.

## A tuning change tested and rejected

The research file ranks "lower the 4 MiB minimum tile" second. Measured with the repo's own
straggler benchmark: **5.92× at a 4 MiB floor, 6.06× at 1 MiB** — the fine case moved from
0.739 s to 0.722 s, i.e. nothing. Reverted.

The real finding is that the benchmark **cannot see this parameter**: its payload is small
enough that the floor never binds, so `testFineTilingBeatsCoarseTilingWhenOneConnectionIsSlow`
would stay green no matter what the floor were set to. Anyone revisiting this needs a
benchmark whose payload is large enough for the floor to bind.

## Pass 4 — XPC boundary, `Persistence`, architecture

Reviewed; **no defects found.** Recorded because "we looked and it was fine" is worth as
much as a finding, and stops the next reviewer re-treading it.

- **`fetchJobRows`** is genuinely N+1-free: one ordered `jobs` scan, three batched
  `WHERE id IN (…)` lookups (each skipped when its key set is empty) and one batched tag
  join, then an in-memory assembly. The statement count is pinned by a test.
- **The 500 ms poll does not ship the full list.** `LibraryModel.startPolling` takes one
  full `listJobs` for a sequence baseline and then uses `pullJobChanges` deltas, with an
  adaptive cadence — 500 ms only while a job is live, 2 s idle on the change stream, 5 s
  when the capability is missing. `drain.idle` short-circuits to an empty batch without
  touching the database.
- **Live progress does reach the UI through the delta stream**, which is not obvious from
  the code: a downloading job's *record* never changes, but `JobProgressLedger.set` calls
  `changeLedger.noteUpsert(jobID)`, so a progress tick is itself a change. Worth knowing
  before anyone "optimises" that call away.
- **The archiver-on-poll trap is already fixed** and documented in place
  (`EngineService.estimatedByteSize`): it uses a per-element constant instead of
  re-serialising the whole job list on every poll purely to produce a number.
- **Import direction holds.** `Presentation` imports no `Persistence`; `Domain` imports
  only `Foundation` and `UniformTypeIdentifiers`. My `project.yml` change added
  `TransferCore` + `TestFaultService` to `RecoveryTests` only — a test target, no
  production edge.

Interaction worth noting: the pass-3 stall fix makes `recordProgress` run on every 250 ms
tick during a transfer, so a stalled job now emits ~4 `noteUpsert`/s where it previously
emitted none. That is the same rate a *moving* job already produced, it is bounded to jobs
with a live transfer, and it is what makes the decaying speed reach the UI at all.

## Review status: complete

Four passes over the engine. The transfer hot path, orchestrator, XPC boundary,
persistence and layering have all been through it.

## Uncommitted pile — worth splitting

Four separate pieces of work are now stacked in one dirty tree: the signed-URL resume slice,
the `resplit` fix, the `SO_RCVBUF`/comment changes, and the stall-decay fix. They are
independent and each has its own tests. Commit them separately before the tree grows further.
