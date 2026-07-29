# COMPLETE — review-driven improvements (hygiene, media resolve, Firefox, XPC hardening)

Slice covering six items agreed after a repo review. Nothing committed or pushed
(RULE 3 — no remote action authorised).

## Evidence

```
make format-check      0/232 files require formatting
make verify-fast       455 tests, 0 failures — incomplete-work-scan: clean — verify-fast: OK
make test-integration  59 tests, 0 failures — ** TEST SUCCEEDED **
make test-recovery      9 tests, 0 failures — ** TEST SUCCEEDED **
```

Unit count moved 440 → 455 (+15 new tests).

## Corrections to the review that prompted this slice

Two of the original findings were wrong and were dropped before any work started:

- **Scheduling is not missing.** `AddDownloadsSheet.scheduleCard` →
  `EnqueueJobRequest.scheduleStartAtISO8601` → `EngineService` →
  `JobRepository` (`state = scheduled`) → `TransferOrchestrator.pump()` calls
  `ProfileRepository.promoteDueScheduledJobs` every tick, covered by
  `Tests/Unit/ProfileAndScheduleTests.swift`. `BandwidthWindowEvaluator` also
  already implements time-of-day windows. The original grep looked for a
  `Scheduler` type that does not exist.
- **`make lint` is not silently degrading.** `Makefile:18` puts `Tools/bin` on
  PATH and the pinned swiftlint is present there.

## Done

### 1. `.gitignore` — release payloads (`.gitignore`)
Ignored `Artifacts/release/*.zip`, `dmg-stage-zip/`, `sparkle/*.zip`,
`sparkle/*.delta`, and loose `Artifacts/validation/*.{log,txt,zip}`.
Deliberately **not** a blanket `Artifacts/release/` — `*.sha256`, `sbom.txt`,
`appcast.example.xml` and `sparkle/*.md` are tracked on purpose. Verified no
tracked file became ignored. `git status` noise: 23 entries → 10.

Two 23 MB zips (`Flow-0.3.1.zip`, `Flow-0.3.2.zip`) are already in history and
still account for most of the 137 MB `.git`. Removing them is a history rewrite
— **not done, needs its own authorisation**.

### 2. Media pages resolve to a queueable download
`YtdlpJSONProbe` parsed `id`/`title`/`format_id`/`is_live`/`_has_drm` and threw
away the `url`, `formats[]` and `http_headers` that `--dump-json` already
returns, so "Check with yt-dlp" printed `OK: <title>` and dead-ended.

- `YtdlpProbeResult` gains `directURL`, `httpHeaders`, `formats`; new
  `YtdlpFormat` with `isProgressive` and `downloadableFormat` (largest
  progressive rendition, falling back to the top-level `url`).
- Non-`http(s)` format URLs (`m3u8://`, `rtmp://`) are rejected — handing one to
  curl would write a playlist named like a video.
- New `Presentation/LibraryWindow/MediaResolution.swift`: pure, view-free
  policy → outcome mapping. DRM and live still block **before** anything is
  offered. Headers are filtered through `HeaderValidator` and serialised with
  `encodeExtraHeadersJSON` into the existing `customHeadersJSON` path, so no new
  plumbing reached the engine.
- `Accept-Encoding` is dropped explicitly: a server honouring it answers a Range
  request with compressed bytes, which invalidates every segment offset.
- Sheet shows a per-item **Queue** action, or the plain reason it cannot queue.
- 13 new tests (`MediaIsolationTests` +5, `MediaResolutionTests` 8).

**Ceilings, deliberate and absent (no stubs):**
- Adaptive DASH/HLS needs a muxer Flow does not have — those pages report
  "only offers separate audio and video".
- A cookie-bearing resolved link skips the range probe (0.3.3 hardening), so it
  downloads on **one connection**. The sheet says so rather than looking broken.

### 3. Firefox companion
`BrowserExtension/firefox/` holds **only** `manifest.json` + README. The
background/popup source is shared verbatim with `chrome/` and staged by
`make browser-extension-firefox` — one copy of the cookie validation in
`background.js`, not two that drift.

`Scripts/lib/write_native_host_manifest.py` gained `--flavor {chrome,firefox}`
(`allowed_extensions` + literal gecko id vs `allowed_origins` + path-derived id).
New `Scripts/install-firefox-native-host.sh` reads the id from the manifest.
Chrome flavour output byte-checked unchanged.

Permanent (non-temporary) installation needs Mozilla signing — out of scope,
same as Safari (ADR 0008).

### 4. `handleMutation` — one place that records the idempotency receipt
19 of 20 mutation handlers repeated the same 12-line ritual, ending in a
hand-written `remember(..., isMutation: true)`. All 20 were correct; the risk was
the 21st. `handleMutation(requestID:reply:failure:body:)` now owns validate →
gate → unwrap DB → execute → **record receipt** → reply. `body` cannot reply on
its own, so the receipt cannot be omitted. `MutationFailure` carries a specific
`XPCErrorCode` out of a body (`invalidPayload` for a malformed field).

`isMutation: true` now appears in exactly two live places: inside the helper, and
in `setBoolSetting`.

`setBoolSetting` is **deliberately not converted** and carries a comment saying
why: it writes user defaults, not the database, and the helper fails closed when
the database is unavailable — converting it would make the setting unwritable
whenever the database is closed.

`EngineService.swift`: 1656 → 1562 lines.

### 5. Bounded decoding at the XPC boundary
New `NSCoder+BoundedDecoding.swift`: `decodeBoundedString`, `decodeUUIDString`,
`decodeOptionalBoundedString` — the cap is the default, and there is no way to
ask for no cap.

Fixed the real drift it was written for: `PullJobChangesRequest` and
`JobChangeBatch` decoded `requestID` with no length cap where every sibling DTO
capped it (caught downstream by `isValidRequestID`, so defense-in-depth, not a
hole). `JobChangeBatch.removedJobIDs` now also bounds count and validates each
identifier — those drive local row deletion.

Note these two are **different kinds of change**. The `requestID` cap tightens
validation on client→engine input, which is the trust boundary. The
`removedJobIDs` check tightens validation on engine→client output, where a
rejection drops the whole batch rather than one entry. That is safe here and was
verified rather than assumed: `noteRemoval` has exactly one caller
(`EngineService.deleteJob`), it passes `request.jobID`, and that value already
passed `UUID(uuidString:)` on the `DeleteJobRequest` decode and originates as
`UUID().uuidString.lowercased()` in `JobRepository`. If a future path ever emits
a non-UUID removal id, loosen this to `decodeBoundedString` + the count bound.

The other ~68 decoders were **not** mechanically rewritten. They already carry
correct caps; sweeping the whole trust boundary at the end of this slice buys
nothing and risks a lot. The helpers exist for new DTOs and for anyone touching
an old one.

### 6. XPC contract drift test
`Tests/Unit/XPCContractDriftTests.swift` pins `EngineControlProtocol`'s selector
set to a checked-in list, so adding an RPC fails the test and updating the list
puts the change in a reviewer's diff — where the other three files get checked.

Originally planned as "enumerate both sides and compare". That does not build:
the protocol is `@objc(DMEngineControlProtocol)` and enumerable, but
`EngineClient` is a plain Swift class and Swift has no method enumeration. The
one-sided pin is the shape that works.

**Mutation-tested**: injecting a bogus selector into the list makes it fail with
`removed: ["deliberatelyBogusSelector:reply:"]`, so the check is not vacuous.

## NOT done

- **Nothing committed or pushed.** No remote action was authorised.
- **History rewrite** for the two 23 MB zips — separate authorisation (RULE 3).
- **Three junk files under `Artifacts/validation/`** —
  `ci-30221356494-failed.log`, `full-gate-tail.txt` contain only a GitHub API
  `Forbidden` line, and `full-gate-job.log.zip` is not a zip at all (`unzip`:
  no end-of-central-directory signature). They are now gitignored but still on
  disk. Deleting them is destructive and left to the owner.
- **Adaptive-stream muxing** (needs ffmpeg) — absent, not stubbed.
- **In-app one-click Firefox setup.** `ChromeCompanionSetupController` is
  Chrome-specific; Firefox is script-only for now.
- **`make verify`** (full evidence bundle) not run — the four lanes above were
  run individually.
- **`make test-asan` / `test-tsan`** not run: no C and no shared-state
  concurrency changed in this slice.
- Splitting `AddDownloadsSheet` (now 1315 lines) / `InspectorView`.
