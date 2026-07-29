# COMPLETE — slice 1: aggregate (process-wide) speed limit

Fixes a correctness defect, not a missing feature: the global and per-host speed
limits were enforced **per transfer**, so N concurrent downloads each ran at the
full configured rate. Nothing committed or pushed (RULE 3).

## Evidence — all five mandated lanes

```
make verify-fast        481 tests, 0 failures — incomplete-work-scan: clean — verify-fast: OK
make test-integration    62 tests, 0 failures — ** TEST SUCCEEDED **
make test-recovery        9 tests, 0 failures — ** TEST SUCCEEDED **
make test-tsan          UnitTests+IntegrationTests+RecoveryTests — 0 ThreadSanitizer warnings, 0 data races
make test-performance     6 tests, 0 failures — ** TEST SUCCEEDED **
    [throughput] straggler tail: coarse=4.35030775s fine=0.737687584s speedup=5.897x
```

Unit 467 → 481 (+14). The straggler benchmark reads **5.897×** against the
documented 5.83× baseline — the added lock did not regress the unlimited path.

`test-asan` deliberately not run: no C changed, no curl handle lifetime changed.

## The defect

`SyncBandwidthGovernor` was constructed once per job
(`SegmentedTransfer.swift:414`, `TransferSession.swift:464`) and fed
`options.maxBytesPerSecond`, a scalar copied into each job by
`effectiveMaxBytesPerSecond`. With `maxActiveJobs = 5`
(`TransferBudgets.swift:23`), five concurrent downloads each got a full-rate
bucket — **up to 5× the number the user typed**. The per-host limit had the
identical defect.

Not a niche path: `BandwidthWindowEvaluator.isActive` returns `true` for an empty
window list and Settings writes `[]` unless the night-window toggle is on, so
this was the ordinary Settings speed limit.

## Design

New `Sources/TransferCore/SharedRateLimiter.swift`. One instance per agent
process, owned by `TransferOrchestrator`.

**Deadline reservation, not a token bucket.** Each charge advances a shared "next
free instant" by `bytes / rate` under the lock, then sleeps after releasing it,
so N concurrent callers serialise into a queue draining at exactly `rate`.

A shared *token bucket* would not have worked and this is the trap worth
recording: each waiter would independently observe a refilled bucket and take its
own full allowance — reproducing the bug being fixed while every existing test
stayed green. That is why `SyncBandwidthGovernor` was left in place for the
per-job budget rather than being shared.

**Sleeps take the max of deadlines, never the sum.** The global and host queues
are charged in one call and the caller waits for whichever is later. Two separate
sleeping calls would add the durations, silently under-delivering the configured
rate with nothing reporting an error.

Separation of concerns after this change:

| Limit | Scope | Enforced by |
|---|---|---|
| per-job | one transfer's own budget | `SyncBandwidthGovernor` (unchanged) |
| per-host | shared across concurrent transfers | `SharedRateLimiter` |
| global | shared across concurrent transfers | `SharedRateLimiter` |

`effectiveMaxBytesPerSecond` is kept and still tested, but is now documented as
**display-only** — it feeds the inspector. Collapsing three differently-scoped
limits into one number and copying it per job is precisely the defect.

Segmented transfers attach one meter at the job level fed the ledger's aggregate
count, and `segmentOptions.rateLimiter = nil` so segments cannot double-charge.

`DownloadOptions.==` is now hand-written to exclude `rateLimiter`: it is shared
infrastructure, not part of what makes two option sets describe the same
transfer.

## Mutation testing — both silent failure modes proven caught

The pre-existing bandwidth test only **lower**-bounds elapsed time, which is why
the defect survived. Every new assertion is an **upper** bound.

1. **Per-caller allowance (the original bug).** Reverting the reservation to
   `let start = now` makes four concurrent 50 KB charges against a 200 KB/s limit
   finish in **0.000077 s** instead of >0.4 s —
   `testConcurrentChargersShareOneGlobalBudget` fails.
2. **Sum instead of max.** Changing the host charge from `max(deadline, …)` to
   `deadline += …` makes an equal-ceilings charge take **1.0001 s** against a
   0.85 s ceiling — `testGlobalAndHostChargesTakeTheMaxNotTheSum` fails.

Both were restored and the suite re-run green.

## Files

- `Sources/TransferCore/SharedRateLimiter.swift` — new (`SharedRateLimiter`,
  `RateLimitedProgressMeter`)
- `Sources/TransferCore/TransferSession.swift` — `rateLimiter` /
  `rateLimitHost` on `DownloadOptions`, custom `==`, meter at the single-stream
  progress site
- `Sources/TransferCore/SegmentedTransfer.swift` — job-level meter; segments
  cannot charge
- `Sources/EngineAgent/TransferOrchestrator.swift` — owns the limiter, publishes
  limits per job, stops copying host/global into per-job options
- `Tests/Unit/SharedRateLimiterTests.swift` — new, 14 tests

No RPC, no migration, no C.

## NOT done

- **Nothing committed or pushed.**
- **`forgetHost` is never called.** The API exists and is tested, but the
  orchestrator does not yet prune. Bounded and small — one `Int64` and one
  `TimeInterval` per host ever downloaded from in an agent's lifetime — but it is
  unbounded in principle and should be wired to the existing `endHostJob`
  teardown in a follow-up.
- Slices 2 onward (yt-dlp reachability, m3u8 leak, and the rest) untouched.
- `make verify` full evidence bundle not run; the five lanes above were run
  individually.
