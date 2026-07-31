# Handoff — segmentation fell back to single-stream far too eagerly — 2026-08-01T2120Z

## Outcome

**COMPLETE (uncommitted)** — both defects that pinned downloads to one connection are
fixed and verified, on the fixtures and against live hosts. Nothing committed or staged;
`AGENTS.md` requires authorization immediately before any commit.

Reported symptom: downloads cap at ~1 MB/s where another download manager reaches 8 MB/s.

Cause: on a 127 ms-RTT link (`cwnd≈77 KB` measured at the CF edge) a single TCP connection
tops out near 0.6–1 MB/s. Throughput on such a link *is* connection count — and two
separate branches were silently disabling segmentation.

## Gate — all six lanes

| lane | result |
| --- | --- |
| `make verify-fast` | 542 unit tests, 0 failures · swiftlint **0.57.1 real** (not the grep backstop), 0 violations · incomplete-work-scan clean |
| `make test-integration` | 67, 0 |
| `make test-recovery` | 9, 0 |
| `make test-performance` | 6, 0 · per-connection cap `1c=2.92s(1.0x) 8c=0.29s(10.1x)` |
| `make test-asan` | 0 sanitizer reports (required — C changed) |
| `make test-tsan` | 0 sanitizer reports |

`make test-asan` / `test-tsan` run `UnitTests + IntegrationTests + RecoveryTests`; the
Makefile's `tail -40` only shows the last bundle's count, which is why the summary line
reads 9. The tests that actually exercise the new C branch were re-run under ASAN
explicitly to confirm the gate is not vacuous — all 15 of
`IntegrationTests/SegmentedTransferIntegrationTests` passed with 0 reports, including
`testProbeSkippingURLKeepsFullBodyWhenHostIgnoresRange` (the `rangedTransfer = 0`
fallthrough), `testExpiringSignedURLStillSegments`, and
`testOpeningChunkFinishesARemainderTooSmallToSplit`.

## Defect #1 — a 200 answer to the range probe permanently disabled segmentation

`probeRangeSupport` sends `Range: bytes=0-0`. CDNs **ignore Range on a cache miss and
honour it on a hit** — measured on one Cloudflare URL seconds apart. The 200 case *throws*
`invalidRangeResponse`, and the catch at `SegmentedTransfer.swift:270` returned
`singleOutcome(...)`: one connection for the life of the download.

Reproduced deterministically with a cache-busting query:

```text
BEFORE  probe FAILED: invalidRangeResponse(httpStatus: 200)   RESULT segments=1
AFTER   probe FAILED: invalidRangeResponse(httpStatus: 200)   RESULT segments=18
```

**Fix.** On `invalidRangeResponse(200)`, recover the total via the existing
`probeForPartialRestart` (plain capped GET) and *attempt* segmentation. New
`segmentedOrSingle(...)` holds the tiling plus the fallback: on `invalidRangeResponse`
**with zero bytes recorded**, remove the sidecar and preallocated shell and run a single
stream. A pass that moved bytes propagates its error instead, so a partial is never wiped
on the strength of one bad response. `runMapLoop` now rethrows `invalidRangeResponse`
immediately — it previously burned all ten stall attempts with backoff up to 30 s each.

Safe to attempt because `DMCurlRangeResponseIsValid` gates every segment on 206 + an exact
`Content-Range` match **before the first `pwrite`**. A host that genuinely ignores Range
writes zero bytes; it cannot produce a right-sized corrupt file.

## Defect #2 — `sig=` in the query disabled segmentation (the user's actual host)

Their real source, from `resources` in the live engine DB:

```text
https://nineanime.ir/download?file=<b64>&expires=1784842480&sig=<hex>&name=<file>.mkv
```

`looksLikeFragileSignedURL` matches `sig`, so `shouldSkipProbe` was true and
`downloadHTTP` returned `singleOutcome(...)` — one connection, every time. Confirmed with
a harness against the live URLs: `nineanime.ir/…&sig=…` → **true**;
`sbp.enterprisedb.com/getfile.jsp?fileid=…` → false. That asymmetry is exactly why their
354 MB EnterpriseDB download behaved and the anime downloads crawled.

**Fix.** The policy is right that such a URL must not be spent on a *throwaway* probe — so
the probe is not resurrected. Instead the **first real chunk doubles as the probe**:

- new C flag `allowFullBodyOn200` on `DMCurlEasyDownloadToFD`, honoured **only when the
  requested range starts at offset 0**. A 200 answer to that ranged request is then
  accepted and written from 0 instead of failing with `rangeResponseInvalid`.
- `openingChunkOutcome(...)` asks for `bytes=0-1048575` with the flag. **206** → the total
  comes from `Content-Range`, the prefix is already on disk, the remainder is tiled and run
  in parallel (same shape as a contiguous-prefix resume). **200** → the whole body was
  written from 0; that *is* the finished single-stream download. **403/other** → nothing
  written, token not consumed, plain GET still succeeds.

Offset 0 is load-bearing: a mid-file segment that accepted a 200 would write the file's
head at its own offset and silently corrupt the download. Mid-file segments keep strict
validation, always.

### Scope limit deliberately kept

Applied **only** to fragile-by-shape URLs that carry an explicit expiry
(`RangeProbePolicy.hasExplicitExpiry`). An expiring signature is re-fetchable until it
expires; a one-shot token is not, and a signature with no expiry says nothing either way.
Credential-bearing jobs (Cookie / Authorization / userpwd / cookie jar) and expiry-less
signatures keep exactly one unranged GET.

That limit is not cosmetic — it was forced by evidence. The first attempt applied the
opening chunk to every probe-skipping URL and broke three
`OrchestratorIntegrationTests` (`…SkipsRangeProbeForCookieJob`, `…ForAuthorizationJob`,
`…ForCookieJarJob`), which assert **zero ranged requests and exactly one request total**
for a one-shot job. That contract is right; the fix was narrowed rather than the tests.

### Truncation bug caught in review, before it shipped

The first version of `openingChunkOutcome` folded "is the file complete?" and "how many
connections for the remainder?" into one guard, returning early when
`preferredSegmentCount(remainder) == 1`. For any total in **(1 MiB, 2 MiB)** — say 1.5 MiB
— the 1 MiB opening chunk leaves 512 KiB, which is below the 1 MiB floor and tiles to one
connection, so the guard fired and the download was reported **complete at 1 MiB**.
`runMapLoop`'s `size == ledger.total` check was never reached, and the orchestrator then
records `expectedSize: outcome.bytesWritten`, so nothing downstream would have caught it.

Fixed by letting only genuine completion short-circuit; a single-connection remainder still
goes through the map loop and is checked against `ledger.total`. `/fixtures/signed-ranged`
is exactly 2 MiB and leaves a 1 MiB remainder, which tiles to 2 — it could not reach the
band at all, so `/fixtures/signed-ranged-awkward` (1.5 MiB) was added. Verified it fails
against the pre-fix code (`1048576` vs `1572864`) and passes after.

### Fast-bail deliberately scoped

`bailOnInvalidRange` is set **only** by `segmentedOrSingle`, the one caller with a
single-stream fallback. Defect #1 is itself proof that a rejected `Content-Range` can be
transient (200 on cache miss, 206 on hit, same URL seconds apart), and on the resume paths
and `openingChunkOutcome` there is no fallback — the throw would reach `handleFailure`,
which spends one of only `RetryPolicy.maxAttempts` (8) whole-job attempts. Those keep their
backoff passes so a later cache hit can still succeed.

### Live proof, signed-URL shape

`cdimage.debian.org/…/debian-13.6.0-amd64-netinst.iso?expires=…&sig=…` (302 → mirror that
honours ranges), `shouldSkipProbe: true` in both runs:

| build | peak TCP connections | bytes in ~26 s |
| --- | --- | --- |
| before | **2** | 205 MB |
| after | **16** observed | 282 MB |

The 16 are sockets still closing between chunk refills, not a budget breach: instrumenting
`curl_multi_perform` shows `running` never exceeds **8**, the value passed as the
concurrency bound (`running=5,6,7,8` only).

## What the measurements do and do not show

The nodejs.org before/after for defect #1 proves **segmentation engages**, not a speed win:
8.87 → 8.29 MB/s, because that host has no per-connection throttle and a single stream was
already fast there. Same caveat for the Debian mirror.

The speed evidence is separate:

- performance lane, per-connection cap: `1c=2.56s(1.0x) 4c=0.52s(4.9x) 8c=0.25s(10.1x)`
- live segmented run on nodejs.org: **9.92 MB/s avg, 14.92 MB/s peak** vs 7.07 single-stream

Segmentation matters exactly where per-connection throughput is capped — the user's
condition, and the one their other download manager was already exploiting.

## New fixtures and tests

- `/fixtures/probe-200-ranges-ok` — 2 MiB; `Range: bytes=0-0` → 200 full body, every other
  Range → 206. The CDN cache-miss shape, made deterministic.
- `/fixtures/signed-ranged` — 2 MiB, honours Range; driven with `?expires=&sig=` so the
  probe-skipping path is exercised by a genuinely range-capable host.
- `testProbe200StillSegmentsWhenRealRangesAreHonoured`
- `testRangeIgnoringHostFallsBackCleanlyAfterSegmentAttempt` — asserts no `.segmap` survives
- `testExpiringSignedURLStillSegments` — the user-reported defect
- `testProbeSkippingURLKeepsFullBodyWhenHostIgnoresRange` — one request, body kept
- `testOpeningChunkFinishesARemainderTooSmallToSplit` — the truncation guard, on
  `/fixtures/signed-ranged-awkward` (1.5 MiB, the only fixture inside the failing band)

Verified against the user's real URL with a harness rather than inferred:

```text
shouldSkipProbe       = true
hasFragileCredentials = false
hasExplicitExpiry     = true
=> opening-chunk path = true
```

Unchanged and still passing: `testCookieJobSkipsProbeOnOneShotURL`,
`testOneShotSurvivesRejectedRangeProbe`, `testFragileSignedQuerySkipsProbeOnOneShotURL`,
`testRangeForbiddenProbeFallsBackToSingleStream`, `NoRangeRestartIntegrationTests`, and the
three orchestrator probe-skip tests.

## Noted, deliberately not fixed

- **Retry storm.** Under HTTP 429 the engine opened **156 fresh TCP connections in 40 s**
  across 6 passes; 115 of 122 easies returned `code=23`/`http=429`/`dl=0`, and no connection
  was ever reused. Real, but measured only under a 429 **provoked by my own repeated
  benchmarking**. The no-reuse half is visible in normal runs too (every easy opens a fresh
  TCP+TLS connection), which costs a handshake per chunk — worth its own slice on a
  high-RTT link.
- **Connection ceiling.** `effectiveHostMaxSegments` clamps to `defaultConnectionsPerJob`
  = 8, so `preferredSegmentCount`'s "up to 32 parallel ranges" branch is dead code. Left
  alone: a clean measurement had 8-parallel curl *slower* than single-stream on nodejs.org
  (4.97 vs 8.41 MB/s), and it is inert anyway unless `maxSocketsPerHost` (32) moves too.
- **Fragile URLs never resume — the obvious next slice.** `singleOutcome` opens with
  `O_TRUNC`, and the probe-skipping branch sits ahead of the segment-map resume logic, so
  these downloads restart from zero. Pre-existing, and `openingChunkOutcome` deliberately
  preserves it (it clears the partial explicitly, since a ranged open does not truncate).
  It matters most for exactly this user: multi-hundred-MB files on a lossy 127 ms link,
  where every failed attempt starts again from zero, up to 8 times. This fix makes each
  attempt roughly 10× faster, which is why it is survivable today rather than fixed.

Also fixed while here: the opening chunk used to hand libcurl's `dltotal` straight to the
UI, and on a 206 that is the **slice** length — the window would read "… / 1 MiB" until the
map loop corrected it. `openingProgress` now withholds any total that is not larger than
the opening chunk, so the UI keeps its existing figure instead of flashing a wrong one.

## Measurement caveat

Repeated benchmarking against `*-speed.hetzner.com` triggered HTTP 429 rate limiting; early
numbers from that host are contaminated and were discarded. Figures above come from hosts
that had not been hammered. The throwaway harness used for live measurement lives in the
session scratchpad (`probe/`) and links the real `TransferCore` / `TransferCurlBridge` /
`CCurl` objects — it is not part of the repo.
