# R&D — competitor feature study, verified gaps, and execution plan

Status: **PLAN ONLY. No code written, nothing committed.**

Method: 5 competitor sites researched from primary sources; 6 domains of Flow
audited against the code; 14 candidate gaps produced; each candidate then given
to **two independent agents whose instructions were to refute it** (one reading
code, one reading CHANGELOG / ADRs / handoffs / git log); only survivors specced.

Why the refutation step exists: twice earlier in this project a "Flow is missing
X" claim was accepted and both were false — scheduling and SwiftLint enforcement
both existed under names the search did not guess. Every claim below survived a
deliberate attempt to disprove it, and every claim's *reasoning* was corrected
where the refuters found it sloppy.

Coverage: 52/55 agents completed. Two spec agents and the sequencing agent hit
the session limit; their inputs survived and the sequencing below is written by
hand from the completed specs.

---

## Part 1 — What the competitors actually ship

Read from primary sources only. Third-party listings were discarded; where a site
was a client-rendered SPA (AB DM) the product's own source repos and string
tables were read instead.

| Product | Source quality | Features |
|---|---|---|
| Free Download Manager 6 | 6 first-party pages incl. changelog | 32 |
| AB Download Manager | own repos + 552-key UI string table | 45 |
| Xtreme Download Manager | homepage + GitHub README | 24 |
| Neat Download Manager | full official site (only 2 pages exist) | 16 |
| Folx 5 (mac-downloader.com) | homepage + 4 subpages | 23 |

Two honesty notes from the research agents, worth keeping:

- The NeatDM agent **refused to list a scheduler or clipboard monitoring**
  despite several SEO content-farm pages claiming both, because no primary
  source corroborated them. That is the correct call.
- FDM's homepage markets "100% clean and open source" while its own download
  page carries no license designation. Reported as marketing, not fact.

### Where Flow already stands even with competitors

Segmented multi-connection transfer, resume of interrupted downloads, browser
extension capture, speed limiting, categories, scheduling, checksum verification,
archive extraction — all shipped. Flow is not behind on the fundamentals.

---

## Part 2 — Verified gaps (12 specced + 2 confirmed, spec pending)

Ranked by user value. Every entry survived two refutation attempts.

### High value

**1. Aggregate speed limit is not aggregate.**
The global speed limit is enforced **per job**. `SyncBandwidthGovernor` is
constructed once per job (`SegmentedTransfer.swift:414`,
`TransferSession.swift:464`) and `maxActiveJobs = 5`, so five concurrent
downloads each run at the full configured ceiling — actual throughput is up to
**5× the number the user typed**. The per-host limit has the identical defect.

This is the most serious finding in the study: the setting silently does not do
what its label says. Note it is not a niche path —
`BandwidthWindowEvaluator.isActive` returns `true` for an empty window list, so
this is the ordinary Settings speed limit.

The refuter found the right seam: `TransferBudgetLedger`
(`TransferBudgets.swift:6-113`) is *already* the process-wide actor doing exactly
this accounting for **sockets**. Bytes are a missing dimension on an object that
already has the right lifetime, layer, and per-host shape. Also found: an async
`BandwidthGovernor` at `TransferBudgets.swift:117-149` that is fully implemented
and **instantiated nowhere**.

Effort M. No RPC, no migration. Lanes: verify-fast, integration, tsan,
performance, recovery.

**2. yt-dlp is unreachable in any shipped build.**
`vendorMediaExecutable` resolves from `fileManager.currentDirectoryPath`, which
for a GUI-launched app is `/` (empirically verified: `lsof` on the Finder pid
reports cwd `/`). So the candidate path is literally
`/VendorBuild/prefix/arm64/media/bin/yt-dlp`, and there is no fallback — no
`Bundle.main` lookup, no PATH probe, no user-chosen path. `find` over both the
installed `.app` and a Release build returns no helper binary.

Everything downstream of it — probe, DRM policy, the resolution work landed
earlier today — is built and tested and **cannot be reached by any user**.

Effort M. No RPC, no migration. Highest risk in the slice is execution
provenance: the resolved path must be writable from exactly one code path (an
NSOpenPanel), never from the native-messaging channel, clipboard, or any XPC
payload.

**3. HLS/DASH streams cannot be downloaded.**
Pasting a `.m3u8` classifies as video and downloads the manifest **text file**.
No parser, no segment fetcher, no concat step exists.

The refuter found this is **worse than claimed**: `YtdlpFormat.isProgressive`
tests codec presence only and never inspects yt-dlp's `protocol` field, and
`httpURL`'s doc comment claims it screens out m3u8 but only catches the literal
`m3u8://` pseudo-scheme. A real HLS URL (`https://cdn/…/720p.m3u8`) passes both.
So the media resolution work landed earlier today **can itself hand a manifest
URL to enqueueBatch**. That is a live defect, not a hypothetical.

This is a RULE 2 case — the comment overstates what the code does.

Effort L. No RPC, no migration, but it wires into `runJob` and four
partial/sidecar lifecycle sites each carrying a data-loss mode.

**4. Max concurrent downloads is hardcoded to 5.**
`TransferBudgets.swift:14` stores it as `private let` with no mutator, and
`main.swift:76` is the sole construction site and passes no budget. Table stakes
in every competitor. Note the per-**host** connection cap (1…32) *is* already
fully user-configurable — a different granularity that already ships.
Effort M. **Needs a new RPC.**

**5. A stale source URL strands the partial.**
A signed CDN link that expired can only be restarted, and restart deliberately
deletes both `.partial` and `.segmap` (`EngineService.swift:577-580`).

Refuter corrections that reshape the work: `updateResourceIdentity` **does**
exist and is already partial-preserving — but it writes `finalURL`, while the
orchestrator dials `canonicalURL`, which is written exactly once at insert and
never updated anywhere. And `setJobFilename` is an exact precedent for a
partial-preserving identity mutation that moves both sidecars without losing a
byte. Effort M. **Needs a new RPC.**

### Medium value

**6. Named queues** with per-queue concurrency and per-queue scheduling.
The claim "no queue entity at all" was **materially wrong** — projects,
categories, batches and tags all exist as named grouping entities wired end to
end. What is absent is per-group concurrency and per-group scheduling.
Effort M. **Needs a migration** (two nullable columns + index).

**7. Recurring / weekday-scoped scheduling.**
The refuter split this correctly: the recurring **trigger** is genuinely absent
(`promoteDueScheduledJobs` is one-way and the schedule row is then deleted, and
the `recurrence`/`timeZonePolicy`/`missedOccurrencePolicy` columns are written
and read by nothing). But a recurring **weekday-scoped permission window**
already ships end to end under the name "bandwidth window". Effort M. No
migration, no new selector.

**8. Shutdown / sleep / quit when the queue drains.**
Four of five competitors ship it. The nearest existing code is the exact inverse
and per-job (`SleepAssertionHolder` prevents sleep), and there is **no aggregate
"queue drained" signal** anywhere in the engine. Note `ProcessInfo.beginActivity`
can only prevent sleep, never cause it. Effort M.

**9. Proxy authentication, system-proxy inheritance, bypass list.**
Unauthenticated proxy works end to end today; credentials, system detection, PAC
and bypass are missing. `keychainPersistentReference` is hardcoded `nil` on every
proxy upsert. Effort L — the spec recommends landing it as **three separately
shippable commits**, security fix first.

**10. Library-wide duplicate detection.**
Dedupe only compares within one paste. The key already exists and is unit-tested
(`CurlURL.normalizationKey`, `CurlBridge.swift:191-215`) and the within-paste UI
is fully built — only the library-wide wiring is absent.
Effort M. **Needs a migration** + a backfill.

**11. Per-job speed/connection limits are read-only after enqueue.**
Read side fully wired, write side exists only at per-**host** granularity — an
asymmetry that inverts what you would expect. Effort M. **Needs a new RPC.**

**12. Filter/search the library by project or tag.**
Full project/tag CRUD ships; the filter enum and search predicate ignore both.
Correction: they are not "decoration" — they are already displayed and sortable
via the Category column. Effort M. No RPC, no migration.

**13. URL pattern expansion** (`file[001-100].jpg` → 100 jobs). Confirmed absent
by 14 distinct searches. FDM and XDM both ship it. **Spec not written** (agent
hit the session limit).

**14. Quick Look preview** from the library. Confirmed absent. **Spec not
written** (same cause).

---

## Part 3 — Execution plan

Written by hand; the sequencing agent did not survive the session limit.

### Ordering principle

Correctness defects before new features. Items 1, 2 and 3 are not missing
features — they are things that **claim to work and do not**. A user who set a
10 MB/s cap and gets 50, or clicks a permanently disabled button, is worse off
than one who never had the feature.

### Slice 1 — Aggregate speed limit *(alone)*

The only slice that touches the byte path. Ships alone.

- Extend `TransferBudgetLedger` with a byte dimension; delete
  `SyncBandwidthGovernor` rather than sharing it — reusing its deficit math in a
  shared object reproduces the exact bug being fixed while every existing test
  still passes.
- Gate: `verify-fast` + `test-integration` + `test-tsan` + `test-performance` +
  `test-recovery`. Performance is mandatory: this adds a lock acquisition per
  progress callback, inside the loop the straggler benchmark measures.
- Acceptance must **upper-bound** throughput. The existing regression test only
  lower-bounds elapsed time and would stay green through the two most likely
  implementation errors (sum-of-sleeps over-throttling, deficit-bucket
  under-throttling).
- Stop condition: if the unlimited-transfer path regresses on
  `TransferThroughputTests`, stop and redesign the fast path as a lock-free early
  return before continuing.
- Rollback: pure revert, no migration.

### Slice 2 — yt-dlp reachable *(alone-ish)*

Turns already-built, already-tested machinery on.

- `MediaHelperLocator`: bundle → user-chosen path (NSOpenPanel) → guarded
  auto-discovery. Reject group/other-writable candidates and their parent dirs.
- The path default must be writable from **exactly one** code path. Flow already
  accepts external input over native messaging — this is a live surface.
- Gate: `verify-fast` + `test-integration` (run it; add no tests — the tree is
  currently dirty from other slices and you need to know whether the lane was
  already red).
- Rollback: pure revert; delete the UserDefaults key.

### Slice 3 — HLS m3u8 leak fix *(small, urgent, split from item 3)*

**Split out of the L-sized stream feature and shipped immediately.** The media
resolution work already in the tree can hand a `.m3u8` URL to `enqueueBatch`
today. Fixing the leak — inspect yt-dlp's `protocol` field and the URL extension,
and `.block` those formats — is a small change that stops a real
corrupt-download path. Full stream *support* is a later, separate L slice.

Gate: `verify-fast` + `test-integration`.

### Slice 4 — cheap, zero-risk batch

Bundle these; none touches the byte path, none migrates:

- Filter/search by project or tag (item 12)
- Quick Look preview (item 14)
- URL pattern expansion (item 13)

Gate: `verify-fast` + `test-integration`.

### Slice 5 onward — one per slice, in this order

| Slice | Item | Why here |
|---|---|---|
| 5 | Max concurrent downloads | new RPC; must follow slice 1 (both touch budgets) |
| 6 | Renew stale URL | new RPC; highest data-loss risk after slice 1 |
| 7 | Per-job limit setter | new RPC; shares DTO surface with slice 5 |
| 8 | Duplicate detection | **migration + backfill — alone** |
| 9 | Shutdown on drain | needs a "queue drained" signal that does not exist yet |
| 10 | Proxy auth | L; three commits, security fix first |
| 11 | Named queues | **migration — alone**; supersedes part of slice 5 |
| 12 | Recurring scheduling | builds on slice 11's queue container |
| 13 | Full HLS/DASH support | L; the whole point of slice 3's split |

### Hard rules for every slice

- **A slice with a migration or a change to where partials live ships alone.**
  Slices 1, 6, 8, 11, 13 qualify. Burying a data-loss surface in a five-feature
  diff is how the risky part stops getting reviewed.
- **Every new RPC** = four files + `ClientHello.capabilities` +
  `XPCContractDriftTests.expectedSelectors`. The drift test now catches three of
  the five.
- **`verify-fast` is never the gate** for slices 1, 3, 5, 6, 7, 8, 9, 10, 11, 13.
- **Migrations are not trivially reversible.** A v9 column cannot be dropped by
  reverting the commit — an already-migrated database keeps the column. Rollback
  means shipping a forward migration.

### What NOT to build

- **BitTorrent downloading** — ADR 0006, settled. FDM and Folx both headline it;
  Flow deliberately does not.
- **Code signing / Mac App Store / signed Safari extension** — ADR 0008, settled.
- **Connection ramp toggle** ("all at once" vs "one by one") — Flow probes before
  opening connections and refills from a finer tiling. That switch exists in
  other managers because they have no probe. A toggle over machinery that already
  ramps correctly risks the straggler benchmark for no gain.
- **Rebuilding per-host connection caps, per-host speed limits, categories,
  category rules, scheduling, bandwidth windows, checksum verification, archive
  extraction, clipboard monitoring, or project/tag CRUD.** All ship today. This
  list exists because two earlier claims in this project asserted a shipped
  feature was missing.
- **A `Scheduler` type.** Scheduling is `promoteDueScheduledJobs` +
  `BandwidthWindowEvaluator`. Searching for the type name finds nothing and
  concludes wrongly.

---

## Provenance and limits

- 3 of 55 agents failed on the session limit: two specs (items 13, 14) and the
  sequencing agent. Both failed items had **completed refutation** — they are
  confirmed gaps, they just lack an implementation spec.
- Two spec agents ran while the safety classifier was unavailable (items 10, 12).
  Their specs should be read with more than usual skepticism before acting.
- Competitor feature claims are only as good as the sites; sourceQuality is
  recorded per product in the raw output.
- Raw data: `/private/tmp/.../scratchpad/rnd.json` (session-scoped, not
  committed).
