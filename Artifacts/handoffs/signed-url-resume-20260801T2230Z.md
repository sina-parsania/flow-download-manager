# Handoff — resume for expiring-signature URLs — 2026-08-01T2230Z

## Outcome

**COMPLETE (uncommitted)** — the follow-up disclosed in
`segmentation-fallback-20260801T2120Z.md`: probe-skipping URLs never resumed, so every
failed attempt restarted from zero, up to `RetryPolicy.maxAttempts` (8) times. Builds on
commit `197849a` on branch `fix/segmentation-single-stream-fallback`. Nothing committed or
staged; `AGENTS.md` requires authorization immediately before any commit.

Why it mattered for the reporting user: multi-hundred-megabyte files on a lossy 127 ms
link. Slice 1+2 made each attempt ~10× faster; this stops each attempt throwing away
everything the previous one downloaded.

## Gate

| lane | result |
| --- | --- |
| `make verify-fast` | 542 unit tests, 0 failures · incomplete-work-scan clean |
| `make test-integration` | 70, 0 |
| `make test-recovery` | 10, 0 |
| `make test-performance` | 6, 0 |
| `make test-asan` | 0 sanitizer reports |
| `make test-tsan` | 0 sanitizer reports |

No C changed in this slice; ASAN/TSAN run anyway because the previous slice's C is still
in the branch.

## The problem

`downloadHTTP`'s probe-skipping branch sat **ahead** of the segment-map resume block, and
both exits from it start clean — `singleOutcome` opens with `O_TRUNC`, and
`openingChunkOutcome` removes the partial explicitly. A `.segmap` written by an earlier
attempt was therefore never even loaded.

The normal resume path validates with `probeRangeSupport` first, and that request is pure
overhead — precisely what these URLs cannot spend.

## The fix

`resumeWithoutProbe` runs before `openingChunkOutcome`. It loads the map and then lets
**the first chunk the map still needs** carry the validation: its response headers answer
"same resource?" while its body is work that had to happen anyway. No throwaway request.

- `remainingWork().first` is used **verbatim** — its `rangeHeader` and `expectedBytes`
  already agree, and the strict validator demands an exact `Content-Range` match, so a
  hand-narrowed window would either be rejected or leave unaccounted bytes on disk.
  Worst-case waste on a `.changed` verdict is therefore one entry (≤4 MiB), once.
- `allowFullBodyOn200: false`, explicitly. The C guard requires `expectedRangeStart == 0`
  so it should never fire, but a map with `baseOffset: 0` puts entry 0 at offset 0 and
  re-opens the question.
- Order is **write → compare → record**, and that ordering is the correctness argument. A
  crash between the write and the wipe self-heals: the ledger still marks the chunk
  incomplete and still holds the old validator, so the next attempt re-fetches, compares
  again, and discards. Recording first would persist the new resource's bytes as progress
  against the old one.
- `chunkProgress` reports `base + written` against `ledger.total`, because libcurl counts
  from zero per request and the UI would otherwise rewind to the size of the chunk in
  flight. (`openingProgress`'s 1 MiB threshold is wrong here — a 4 MiB validator chunk
  would sail through it and show "… / 4 MiB".)

Any error on the validating chunk propagates untouched. Nothing is wiped, so the job's
retry path keeps the bytes.

## Tests — all three verified red before green

- `testSignedURLResumesFromSegmentMap` — request **count** is the discriminator, since
  resume and restart both issue only ranged GETs and both end with correct bytes. One
  incomplete entry ⇒ resume issues exactly **1** request; a restart spends one on the
  opening chunk and re-tiles the remaining 1 MiB into two more. Measured **3 vs 1** with
  the fix disabled.
- `testSignedURLResumeDiscardsPartialWhenValidatorContradictsServer` — stored ETag
  contradicts the server; partial seeded with `0xFF`, which appears nowhere in the
  fixture, so a surviving byte is detectable. Must be discarded and re-downloaded whole.
- `testSignedURLResumeKeepsPartialWhenValidatorRequestFails` — connection refused (port 1)
  is not a verdict about the bytes. With the fix disabled this left a **0-byte partial and
  no segmap**; it now keeps both at full size.

## A destructive bug in the first draft, caught in review

`guard let work = ledger.remainingWork().first else { return nil }` looked like a harmless
"nothing to resume". It was not: `nil` routes the caller into `openingChunkOutcome`, which
deletes the partial **and** the sidecar and re-requests from byte 0. A map whose entries
are all complete — with the finished, correct file sitting next to it — was therefore
deleted and downloaded again.

That state is not exotic. `runMapLoop` ends with `markCompleted()` persisting a map with
every entry full → **full-file `fsync`** → size check → `deleteSidecar()`. Anything that
kills the process inside that `fsync` leaves exactly it, and on a large file on external
storage the window is seconds wide.

The empty case now goes to `runMapLoop` like the normal resume path does: it finds no work,
verifies `size == ledger.total`, drops the sidecar and reports success — the completion the
killed run was two steps away from. It needs an identity with no request to get one from,
so `ledgerIdentity` synthesizes one from the map (`etag`/`lastModified` from the stored
validator; `runMapLoop` overrides `contentLength` with `ledger.total` regardless).
`contentType` and `contentDisposition` come back nil, so filename refinement falls back to
the evidence the job already had — a far better trade than re-downloading a finished file
to recover two header values.

`Tests/Recovery/SegmentMapCrashRecoveryTests.swift` covers it, in the lane whose job this
is. Verified red before green: **3 requests instead of 0**, i.e. it really did re-download
the file. Adding it required `TransferCore` + `TestFaultService` on the `RecoveryTests`
target in `project.yml`, then `make project`.

## Known limits — disclosed, not bugs

**Expired signatures.** An `expires=` that has already passed makes the resume request 403,
and the job spends its 8 attempts on a signature that cannot come back. The user's own
stored URL had `expires=1784842480`, already in the past. For long downloads this will
sometimes be unrecoverable and the link has to be re-added — inherent to expiring
signatures, not something resume can fix.

**A contiguous prefix with no segment map is still discarded.** When
`openingChunkOutcome` gets a **200** it writes the whole body through
`downloadSingleStream` and never creates a ledger. Interrupted at 400 MB of 700 MB, the
next attempt finds no map, `resumeWithoutProbe` returns nil, and the prefix is deleted.
Not a regression — `singleOutcome`'s `O_TRUNC` did the same — but it is exactly the shape
of a cache-missing CDN serving a large file, which is this user's situation. The normal
path covers it via `resumeWithSegments` / `resumeOrDownload`, neither of which is reusable
here because `resumeWithSegments` calls `probeRangeSupport`. Next slice, if it bites.

## Still open from the previous slice

- ~~**No connection reuse.**~~ **Retracted — this was wrong.** Re-measured against a real
  keep-alive host: **144 easy handles, 29 TCP connections** (~5 chunks per connection).
  Reuse works. The original "156 connections in 40 s" was taken under the HTTP 429 I
  provoked, where error responses close the connection, and `FaultHTTPServer` sends
  `Connection: close` on every response — so neither source could show reuse.
- **Connection ceiling** stays at `defaultConnectionsPerJob = 8`, making
  `preferredSegmentCount`'s "up to 32" branch dead code. Inert unless `maxSocketsPerHost`
  (32) moves too.
