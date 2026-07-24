# Codebase Architecture and Performance Improvement Plan

- Status: `IN PROGRESS — P0 (partial), P1, P2 landed 2026-07-24; P3+ open`
- Plan owner: repository maintainer
- Baseline commit: `ccdacdc` (`main`, 2026-07-24)
- Scope: implementation authorized for high-ROI phases; see handoff
  `Artifacts/handoffs/v0.3-arch-slice-20260724T1846Z.md`
- Top recommendation: deepen the Library projection path (P2 done; P3 next)
- Visual review: `/private/var/folders/yy/srxs_hv17w7fqzcqvxrd3dwr0000gn/T/architecture-review-20260724T173823Z.html`

The visual review is a session-local discovery artifact required to remain
outside the repository. This plan is the durable, self-contained artifact and
does not depend on the temporary file remaining available.

## 1. Outcome

Improve Flow’s codebase architecture and performance by concentrating behavior in
deep modules at existing seams, removing verified hot-path amplification, and
turning performance from proxy diagnostics into a reproducible release gate.

The plan must deliver all of the following without weakening repository gates:

1. A bounded XPC request lifecycle with no connection-lifetime response growth.
2. A deep Library projection module whose persistence work does not grow in SQL
   statement count with the number of jobs.
3. Change-aware, sequence-correct Library delivery that does not rebuild and
   transfer unchanged rows every second.
4. A deep progress telemetry module with bounded pending work independent of raw
   libcurl callback frequency.
5. A deep Scheduler module that owns runnable selection, fairness, wake deadlines,
   and activation without fixed high-frequency idle polling.
6. One reproducible performance evidence module implementing the normative
   baseline/compare workflow and all applicable NFR measurements.
7. Preserved user-visible behavior, recovery invariants, XPC security, and
   transfer throughput.

This is not an interface-design document. Exact interfaces are selected only
after the candidate decision/grilling step and must satisfy the constraints and
tests in this plan.

## 2. Planning principles

- **Module:** each recommendation names the behavior it owns, not a file split.
- **Interface:** callers and tests use the same small, behavior-oriented surface.
- **Depth:** behavior moves behind an interface; new pass-through modules are
  rejected.
- **Seam:** use existing process, persistence, clock, and transfer-adapter seams.
- **Adapter:** introduce one only when behavior really varies. Production XPC and
  in-process XPC tests are two adapters; single-stream and multi-segment progress
  are two adapters.
- **Leverage:** prefer a single implementation that benefits many commands,
  callers, and tests.
- **Locality:** projection, replay, scheduling, and progress invariants each live
  in one module.
- **Deletion test:** a candidate is accepted only if deleting it would spread
  real complexity across callers. A file extraction that merely relocates code
  is rejected.
- **Interface is the test surface:** tests assert observable behavior at the same
  seam used by production callers. Tests that depend on internal helpers are
  replaced after parity is proven.
- **Replace, do not layer:** once a deep module is proven, remove superseded
  shallow implementations and their implementation-coupled tests in the same
  phase.

## 3. Current evidence

### 3.1 Repository state

- Baseline branch/commit: `main@ccdacdc`.
- Working tree contained one pre-existing untracked user file,
  `Documentation/diagnosis-intake.md`; it is outside this plan and must remain
  untouched.
- No `CONTEXT.md` or `UBIQUITOUS_LANGUAGE.md` exists. Existing domain terms used
  here are job, queue, transfer, engine agent, Library read model, profile,
  schedule, and progress snapshot.
- The latest handoff reports 185 unit tests passing, but this planning pass did
  not rerun product tests because no product code was changed.

### 3.2 Change concentration

Across the recent 35-commit history:

| File/module | Changes |
|---|---:|
| `Sources/EngineAgent/EngineService.swift` | 13 |
| `Sources/XPCContracts/EngineControlProtocol.swift` | 11 |
| `Sources/XPCContracts/EngineControlInterface.swift` | 11 |
| `Sources/Presentation/EngineClient.swift` | 11 |
| `Sources/Persistence/JobRepository.swift` | 11 |
| `Sources/EngineAgent/TransferOrchestrator.swift` | 11 |
| `Sources/Presentation/LibraryWindow/LibraryModel.swift` | 9 |
| `Tests/Unit/XPCCodingTests.swift` | 9 |
| `Tests/Unit/JobRepositoryTests.swift` | 9 |

This concentration defines the scan scope. The plan does not expand into media,
torrent runtime completion, installer work, UI restyling, or unrelated modules.

### 3.3 Confirmed performance amplification

1. `LibraryModel.startPolling` refreshes once per second.
2. Every refresh calls `EngineClient.listJobs`, which creates a new UUID request
   identifier.
3. `EngineControlExporter.listJobs` stores the complete response by request
   identifier in `listCache`.
4. The exporter declares 27 response-cache dictionaries, including `listCache`;
   none has an observed size, age, or retained-byte bound, and each lives as long
   as the connection.
5. `JobRepository.fetchJobRows` fetches all jobs, then performs resource,
   category, optional project, and tag reads per job. The statement count is at
   least `3N + 1` and can reach `4N + 1`.
6. The agent maps every persistence row to a DTO, XPC copies the complete list,
   and the main-actor Library model reconstructs every row on every poll.
7. Current 10,000-row tests measure generated fixtures, in-memory filtering, and
   a diffable table apply. They do not measure persistence projection, XPC
   transfer, agent mapping, main-actor mapping, idle polling, or cache retention.
8. The normative validation contract requires `make performance-compare`, but
   the Makefile implements no such target.
9. The checked-in Phase 0 baseline predates the recent Phase 1–5 work and is not a
   current before-measurement.

### 3.4 Confirmed architecture friction

- `EngineControlExporter` is 1,573 lines and repeats the handshake guard in 27
  command handlers, along with request validation, locking, availability checks,
  replay handling, error translation, and reply completion.
- `TransferOrchestrator` is 671 lines and currently owns queue polling, schedule
  promotion, bandwidth-window parsing, budget acquisition, transfer lifecycle,
  retry handling, host observations, progress, finalization, and ZIP
  post-processing.
- Its queue pump wakes every 200 ms, including while idle, and re-reads/re-parses
  schedule policy during the loop.
- A raw transfer progress sample creates an unstructured task that hops to the
  orchestrator actor. Multi-segment progress also reduces the segment progress
  array under a lock per sample, while the UI reads progress once per second.
- The app and Chrome native host each own XPC connection/handshake behavior; the
  app path has stronger interruption/reconnect behavior than the native-host
  path.

### 3.5 Contracts that must remain authoritative

- The engine agent remains the sole persistence and final-file writer.
- Presentation never reads persistence directly.
- The UI never owns sockets, partial files, checkpoints, or queue activation.
- Snapshot delivery uses monotonically increasing sequence numbers; a gap causes
  a full refresh.
- ADR 0003 fail-closed audit-token/code-signing validation remains unchanged.
- ADR 0007 native-host role and allowlisted command behavior remain unchanged.
- Warnings-as-errors, Swift 6 complete concurrency, safety scans, sanitizer
  lanes, and the no-incomplete-work rule are never weakened.
- A performance regression above 10% requires explanation and release-owner
  approval; an NFR threshold failure blocks the phase.

## 4. Requirements and traceability

| ID | Requirement | Planned phase | Primary proof |
|---|---|---|---|
| ARCH-001 | Library projection behavior has one deep module | P2 | parity suite + deletion-test review |
| ARCH-002 | XPC request lifecycle behavior has one deep internal module | P1/P6 | protocol round trips + fault matrix |
| ARCH-003 | Progress aggregation/coalescing has one deep module | P4 | synthetic load + transfer integration |
| ARCH-004 | Runnable selection/fairness has one deep Scheduler module | P5 | deterministic clock/queue matrix |
| ARCH-005 | App/native-host connection semantics share one deep session module | P7 | two-adapter parity matrix |
| PERF-001 | Response retention is bounded and reaches a memory plateau | P1 | four-hour retention soak |
| PERF-002 | Library persistence statement count is constant with row count | P2 | SQL counter + query-plan artifact |
| PERF-003 | Steady Library delivery is change-aware and sequence-correct | P3 | 10k end-to-end benchmark + gap tests |
| PERF-004 | Progress work is bounded by publication policy, not callback count | P4 | million-sample benchmark |
| PERF-005 | Idle queue evaluation avoids fixed 200 ms polling | P5 | wakeup/DB-read trace |
| PERF-006 | Baseline comparison is reproducible and release-blocking | P0/P8 | `make performance-compare` evidence |
| REL-001 | No state-machine, recovery, idempotency, or ordering regression | all | unit/integration/recovery suites |
| SEC-001 | XPC peer validation and redaction remain fail-closed | P1/P3/P6 | security-focused round trips/review |
| COMP-001 | N-1 app/agent transition has defined behavior | P3/P6 | compatibility matrix |
| DOC-001 | Every phase produces traceability and a complete handoff | all | handoff/evidence inspection |

## 5. Performance contract

Phase P0 records current-main measurements before any implementation. These
targets are the acceptance contract; changing them requires a plan revision and
release-owner approval, never an implementation-only edit.

Threshold provenance:

- The `>10%` regression rule and required scenario families are normative from
  `05-quality-testing-release-gates.md`.
- Absolute latency, CPU, memory, wakeup, and publication targets below are
  provisional product budgets proposed by this plan. DG-1 ratifies or tightens
  them against the reproducible current-main baseline before P1 starts.
- DG-1 may not loosen a provisional budget merely because current-main misses it.
  A looser budget requires a documented user-impact rationale, Reviewer
  objection/response, and release-owner approval.
- Proxy diagnostics such as fixture construction, isolated query time, and table
  apply time locate cost. Only the stated persistence → engine → XPC →
  Presentation scenarios decide end-to-end acceptance.

| Metric | Scenario | Acceptance target |
|---|---|---|
| Library full projection SQL statements | 1, 100, 1,000, 10,000 jobs | Constant with N; no more than 4 statements |
| Library full refresh | 10,000 jobs, persistence → XPC → read model | p95 ≤ 1,000 ms on approved baseline machine |
| Library steady update | 10,000 jobs, 1% changed | p95 ≤ 100 ms end to end |
| Main-actor steady update | 10,000 jobs, 1% changed | p95 ≤ 16.7 ms; no >100 ms hitch |
| XPC steady payload | 10,000 jobs, 1% changed | proportional to changed rows; full list only on first load/gap |
| Retained response memory | 10,000 jobs, 1 Hz requests, 4 hours | plateau after warmup; RSS slope ≤ 1 MiB/hour |
| XPC replay storage | reads and mutations | explicit count/age/byte bounds; deterministic eviction tests |
| Idle CPU | UI open, 10,000 static jobs, no transfer, 10 minutes | UI and agent median ≤ 1% each; p95 ≤ 2% each |
| Idle wakeups/DB reads | same idle scenario | no fixed 1 Hz UI or 5 Hz queue polling; event/deadline driven |
| Progress pending work | 1/8/32 segments, 1,000,000 samples | bounded; no linear task backlog |
| Progress publication | active job | ≤ 10 Hz average, ≤ 250 ms observable staleness, exact terminal sample |
| Queue start latency | eligible job, capacity available | p95 ≤ 250 ms |
| Scheduled start drift | fixed clock fixtures | ≤ 250 ms excluding OS sleep; defined wake behavior after sleep |
| Transfer throughput | controlled 1/2/4/8/16 segment fixtures | no >10% regression from same-machine baseline |
| Memory safety | app/agent four-hour soak | no confirmed leak; bounded growth |
| Performance comparison | approved same-class baseline | >10% regression fails with metric-level explanation |

Machine comparability requires:

- model, chip, physical memory, storage model/filesystem;
- macOS, Xcode, Swift, app commit/build configuration;
- power source/mode, Low Power Mode, thermal state, display state;
- test fixture hash and dependency-manifest hash;
- at least one warmup and five recorded samples;
- coefficient of variation ≤ 5% for gating metrics, otherwise rerun and classify
  the environment as non-comparable.

Measurement definitions:

- `p95` is computed from at least 30 post-warmup iterations; raw samples are
  retained.
- CPU is per-process CPU time divided by wall time over the stated interval,
  reported separately for app and agent.
- Main-actor duration is signpost interval time for read-model application, not
  total background projection time.
- RSS slope uses least-squares slope after a 15-minute warmup and is corroborated
  by Allocations/Leaks retained-growth evidence.
- Wakeups and persistence reads come from signposts/File Activity plus explicit
  debug-only counters excluded from release behavior.
- Payload size is the securely archived XPC DTO byte count measured before send
  and after receive; it excludes unrelated process memory.
- A result is `NOT COMPARABLE`, never pass, when required metadata, sample count,
  variance, or fixture hashes do not satisfy this section.

## 6. Candidate priority and decision gates

| Priority | Candidate | Strength | Dependency category | Decision |
|---:|---|---|---|---|
| 1 | Deep Library projection path | Strong | ports & adapters + local-substitutable persistence | Default first architecture target |
| 2 | Bounded XPC request lifecycle | Strong | in-process/local-substitutable | Immediate safety prerequisite |
| 3 | Performance evidence module | Strong | local-substitutable | Required before behavior changes |
| 4 | Transfer progress telemetry | Strong | two local transfer adapters | Independent after Library path |
| 5 | Scheduler module | Strong | local-substitutable | After measurement and query-plan proof |
| 6 | Shared XPC client session | Worth exploring | two owned adapters | After snapshot protocol stabilizes |

Decision gates:

1. **DG-0 Candidate gate:** maintainer may change the default candidate ordering
   after reviewing the visual report. No interface design begins before this
   decision.
2. **DG-1 Baseline gate:** P0 evidence is reproducible and the current performance
   failures are quantified.
3. **DG-2 Safety gate:** response retention is bounded before long-running
   Library benchmarks are trusted.
4. **DG-3 Projection gate:** P2 parity and constant-statement proof pass before
   any snapshot-delivery protocol change.
5. **DG-4 Delivery gate:** N/N-1 and sequence-gap behavior pass before periodic
   polling is removed.
6. **DG-5 Telemetry gate:** terminal exactness and bounded pending work pass
   before the old progress path is deleted.
7. **DG-6 Scheduler gate:** fairness/recovery matrices pass before the fixed pump
   is deleted.
8. **DG-7 Request-locality gate:** server-side request behavior passes all 27
   command/fault matrices before repeated request mechanics are deleted.
9. **DG-8 Release gate:** same-machine comparison, full stable validation, and
   handoff evidence pass.

### 6.1 Decision ownership

| Decision/artifact | Responsible | Approver | Required evidence |
|---|---|---|---|
| Candidate order and selected deep module | architecture implementer | repository maintainer | visual report + deletion test |
| Exact interface at a seam | phase implementer | repository maintainer + independent Reviewer | grilling/design-it-twice record |
| Baseline capture and comparator | performance owner | release owner | raw samples + machine manifest + self-test |
| Approved before-baseline promotion | performance owner | release owner | immutable candidate hash + reproducibility rerun |
| XPC replay/idempotency semantics | Engine/XPC owner | security reviewer + repository maintainer | duplicate/eviction/restart matrix |
| Protocol compatibility window | XPC owner | repository maintainer | N/N-1 matrix |
| Phase completion | phase implementer | independent Reviewer | raw validation bundle + handoff |
| Threshold exception | performance owner | release owner | user-impact rationale + debate revision |

The same person may implement and collect evidence, but cannot be the independent
Reviewer for the same phase.

## 7. Execution roadmap

Each phase is an independently reviewable vertical slice. Only one phase is in
scope at a time. Implementation starts only after explicit authorization.

### P0 — Establish trustworthy performance evidence

#### Objective

Deepen the performance evidence module before optimizing product code.

#### Planned changes

- Preserve the existing approved baseline; never overwrite it in place.
- Produce immutable, timestamped candidate baselines and a machine manifest.
- Implement the normative `make performance-compare BASELINE=<path>` interface.
- Extract structured metrics from XCTest/Instruments artifacts into JSON.
- Compare only compatible machines/configurations and fail closed when metadata
  is incomplete.
- Add deterministic scenarios for:
  - 10,000-job persistence → XPC → Library projection;
  - one-hour and four-hour 1 Hz request-retention soak;
  - idle app/agent CPU, wakeups, DB reads, and RSS;
  - 100 queued jobs across multiple hosts;
  - progress callback pressure at 1/8/32 segments;
  - controlled transfer throughput at 1/2/4/8/16 segments.
- Record signposts for persistence projection, XPC encode/decode, snapshot apply,
  queue evaluation, progress aggregation/publication, and job activation.

#### Tests first

- Comparator tests for improvement, ≤10% regression, >10% regression, missing
  metric, incompatible machine, noisy sample, and malformed artifact.
- Manifest tests for every required comparability field.
- A self-test fixture whose known regression must fail the command.

#### Acceptance

- `make performance-baseline` writes a new immutable candidate artifact.
- `make performance-compare BASELINE=...` returns nonzero for a seeded >10%
  regression and zero for a compatible non-regression.
- End-to-end Library and retention scenarios fail on current amplification or
  record an explicit current-main baseline; proxy-only results cannot close P0.
- A second same-environment run reproduces every gating metric within the
  comparability rules before the release owner promotes the candidate baseline
  by immutable content hash.
- Candidate capture and approved-baseline promotion are separate commands;
  capture can never overwrite the approved input path.
- Raw result bundles, metric JSON, environment manifest, and command logs exist.

#### Stop rule

Stop if measurement variance remains above 5% after environment normalization.
Do not optimize against unstable measurements.

### P1 — Bound XPC replay and response retention

#### Objective

Remove the unbounded connection-lifetime growth before deeper Library changes.

#### Planned changes

- Define separate replay semantics for reads and mutations.
- Before implementation, classify every command by side-effect/idempotency
  behavior and define the required duplicate-detection horizon for same
  connection, reconnect, agent restart, and client crash.
- Compare at least two safe designs during grilling: bounded session replay and
  an additive durable idempotency ledger with retention/compaction. Select only a
  design that proves enqueue and other non-naturally-idempotent mutations cannot
  execute twice inside the documented horizon.
- Put request validation, replay lookup, concurrent-duplicate coordination,
  deterministic eviction, and retained-byte accounting behind one internal
  request-lifecycle seam.
- Keep ADR 0003 peer validation outside and before this seam.
- Preserve exactly-once mutation behavior for concurrent duplicate identifiers.
- Ensure read requests do not retain complete snapshots indefinitely.
- Expose only redacted counters/signposts needed to prove bounds.

#### Tests first

- 10,000-job, 1 Hz, four-hour equivalent retention test using a controllable
  clock and memory-accounting adapter.
- Concurrent duplicate mutation: implementation executes once, replies replay.
- Duplicate read and mutation behavior before/after eviction, reconnect, client
  crash, and agent restart.
- Enqueue duplicate tests must assert one durable batch/job set, not merely one
  reply object.
- Malformed identifier, pre-handshake request, connection interruption,
  invalidation, and reconnect races.
- Deterministic count/age/byte eviction ordering.
- If a durable ledger is selected: migration, pruning, crash-between-mutation-and-
  receipt, backup/restore, and downgrade compatibility.

#### Acceptance

- Replay storage has explicit count, age, and retained-byte bounds.
- Four-hour soak reaches the memory target in the performance contract.
- The selected design documents the guarantee horizon and returns a typed
  fail-closed result outside it; no ambiguous re-execution is allowed.
- No mutation path ships until enqueue and every other non-naturally-idempotent
  command passes eviction/reconnect/restart tests.
- Existing XPC coding/round-trip/security tests pass.
- No cache mechanics leak into the public XPC interface.
- The old unbounded dictionaries are deleted, not retained behind another module.

#### Rollback

The protocol wire shape remains unchanged. If the selected safe design needs an
additive idempotency table, land its backward-compatible migration separately,
prove downgrade/read compatibility, and retain the table during code rollback
until a later explicitly approved cleanup. If no safe reversible design satisfies
the mutation guarantee, mark P1 `BLOCKED` and do not substitute best-effort replay.

### P2 — Deepen the Library persistence projection

#### Objective

Replace per-job persistence fetches with one deep projection implementation.

#### Planned changes

- Capture behavior parity fixtures before modifying persistence.
- Concentrate job ordering, resource/category/project/tag aggregation, invalid-row
  handling, and static display evidence inside the Library projection module.
- Replace per-job reads with a bounded set-based query plan.
- Add only indexes proven necessary by `EXPLAIN QUERY PLAN`.
- Keep live progress as an overlay owned by the engine; do not persist high-rate
  progress merely to simplify reads.
- Return one immutable internal projection consumed by the XPC adapter.
- Keep Presentation isolated from GRDB.

#### Tests first

- Golden parity across empty, mixed-state, projectless, tagged, Unicode, and
  malformed-reference fixtures.
- Ordering parity for priority, queue position, and creation time.
- SQL statement counter at 1/100/1,000/10,000 jobs.
- Query-plan assertions for ordering and joins.
- Corrupt/missing related-row failure semantics.
- Concurrent engine progress overlay with static projection.

#### Acceptance

- SQL statement count satisfies the performance contract.
- Projection output is behaviorally identical to the approved pre-change
  fixtures.
- 10,000-job persistence projection meets its phase budget and improves the
  current baseline materially.
- No N+1 persistence access remains.
- Superseded tuple/projection code and implementation-coupled tests are removed.

#### Rollback

Indexes are additive and independently removable. No destructive schema
migration is permitted in this phase.

### P3 — Make Library delivery change-aware and sequence-correct

#### Objective

Stop unconditional full-list polling while preserving reconnect and gap recovery.

#### Planned changes

- Select the smallest interface that supports immutable initial state,
  monotonically increasing sequences, coalesced changes, and full refresh after
  a gap.
- Negotiate capability through the existing version handshake.
- Preserve `listJobs` as the real full-refresh/recovery path, not a deprecated
  stub.
- Make the engine own delivery throttling independently from durability
  checkpoints.
- Update only changed read models in Presentation while preserving identity,
  selection, filtering, terminal notifications, and ETA smoothing.
- Define N/N-1 app/agent behavior for upgrade, reconnect, and resubscribe.
- Bound payload size and collection count under the existing XPC security rules.

#### Tests first

- Initial subscription/full refresh, ordered changes, duplicate sequence, stale
  sequence, sequence gap, reconnect, agent restart, client cancellation.
- N/N-1 capability and fallback matrix.
- Matrix rows include: app N ↔ agent N, app N ↔ agent N-1, app N-1 ↔ agent N,
  agent replacement during an active subscription, unsupported minor capability,
  interrupted handshake, and old agent left running across app update.
- 10,000 static jobs with 0%, 1%, and 100% changed.
- Selection and notification correctness under coalescing.
- Payload limit and malformed DTO rejection.
- TSan/Main Thread Checker for delivery/cancellation races.

#### Acceptance

- Steady-state latency, main-actor time, payload proportionality, CPU, and wakeup
  targets pass.
- A sequence gap deterministically triggers a full refresh.
- There is no fixed 1 Hz full-list poll after the new path is active.
- Old and new adapters do not create divergent business rules.
- Every N/N-1 matrix row has one of: compatible change-aware delivery, compatible
  full-refresh fallback, or typed upgrade-required rejection. Silent downgrade,
  unknown selector invocation, and mixed sequence semantics fail the phase.
- The compatibility window and removal condition are documented; the recovery
  path cannot be removed while any supported pair depends on it.
- Protocol/version/traceability documentation is updated.

#### Rollback

The full-refresh path remains complete and tested for recovery and N-1
compatibility. Reverting change-aware delivery does not require data rollback.

### P4 — Deepen transfer progress telemetry

#### Objective

Bound progress work and place all progress invariants in one deep module.

#### Planned changes

- Treat single-stream and multi-segment progress sources as two adapters at one
  real seam.
- Concentrate O(1) aggregation, monotonic bytes, speed estimation, coalescing,
  latest-value storage, bounded publication, and terminal exactness.
- Prevent one unstructured task per raw callback.
- Ensure cancellation/terminal transitions reject late samples.
- Keep UI delivery cadence separate from transfer callback cadence.
- Prepare the module for future torrent/media adapters without adding those
  adapters now.

#### Tests first

- One million synthetic samples at 1/8/32 segments.
- Monotonic bytes, nonnegative speed, reset semantics, no post-terminal update,
  exact terminal byte count.
- Bounded pending-work assertion under a deliberately slow consumer.
- Maximum publication frequency and maximum observable staleness.
- Pause/resume/cancel/retry races and existing curl-multi integration paths.

#### Acceptance

- Pending work is bounded independent of sample count.
- Publication/staleness targets pass.
- CPU per transferred GiB does not regress and improves under high callback load.
- Transfer throughput remains within the normative 10% budget.
- Old per-sample task and O(segments) aggregation paths are deleted.

#### Rollback

No persistence or wire migration. Revert as one transfer-internal slice after the
existing progress integration suite proves parity.

### P5 — Deepen queue activation into the Scheduler module

#### Objective

Move eligibility, fairness, wake deadlines, and claims out of the fixed pump.

#### Planned changes

- Keep transfer execution behind its existing deep module.
- Concentrate priority/order, schedule windows, bandwidth calendar, budget
  availability, fairness, next wake deadline, and atomic queue claim in Scheduler.
- Drive evaluation from enqueue/resume/completion/policy-change/recovery events
  and calculated deadlines.
- Retain a bounded low-frequency safety wake only if falsification tests prove it
  necessary.
- Cache parsed policy only with explicit invalidation/version semantics.
- Add indexes only after query-plan evidence.
- Use monotonic time for durations and an injected wall-clock/calendar adapter
  for schedule semantics.

#### Tests first

- Deterministic clock matrix including midnight, DST transitions, time-zone
  change, sleep/wake, missed occurrence, and policy update.
- Priority/fairness/budget matrix across 100 jobs and multiple hosts.
- Enqueue-to-start and completion-to-next-start latency.
- Repeated pause/resume/cancel/retry/restart races.
- Idle DB-read/wakeup trace and queued-query plan.

#### Acceptance

- Queue latency and scheduled-drift targets pass.
- Idle fixed 200 ms polling is gone.
- Active-job, total-socket, and per-host budgets never oversubscribe.
- Recovery preserves state-machine legality and partial-file ownership.
- The old pump policy implementation is deleted after parity.

#### Rollback

No destructive migration. Scheduler activation must be one revertible phase; any
new index is separately reversible.

### P6 — Deepen server-side XPC request locality

#### Objective

Finish the internal request-lifecycle module after snapshot semantics stabilize.

#### Planned changes

- Complete the internal request-lifecycle module so the 27 exporter handlers no
  longer repeat handshake/session/request/error mechanics.
- Keep the exported XPC protocol adapter thin and explicit.
- Do not generate XPC contract code or redesign DTOs unless a separate
  design-it-twice review proves higher depth and equal secure-coding auditability.

#### Tests first

- All 27 command behaviors through the protocol seam.
- Request validation, handshake gating, typed failure translation, replay policy,
  concurrent duplicate coordination, and reply completion faults.
- Anonymous-listener round trips, TSan, and signed-path manual validation when
  release infrastructure is available.

#### Acceptance

- Shared request invariants exist in one implementation.
- Exporter handler implementations contain command-specific validation and
  behavior, not repeated session mechanics.
- ADR 0003/0007 constraints and XPC secure-class allowlists remain auditable.
- Deleting the deep module would demonstrably spread real complexity; no
  pass-through modules remain.

#### Rollback

No protocol change in this phase. If P1 selected an additive idempotency ledger,
its downgrade rule remains authoritative. Revert the server-internal slice
without changing app/native-host clients.

### P7 — Deepen the XPC client session

#### Objective

Concentrate connection/handshake/reconnect semantics used by the app and native
host after the server-side request behavior is stable.

#### Planned changes

- Treat app and native-host XPC clients as two real adapters at one session seam.
- Concentrate connection ownership, handshake negotiation, continuation
  completion, reconnect policy, interruption handling, and role/capability
  validation in one deep client-session module.
- Preserve distinct app/native-host role restrictions.
- Preserve non-main-actor callback completion fixed by recent concurrency work.
- Keep command-specific DTO construction in the appropriate adapter unless the
  grilling step proves moving it increases depth.

#### Tests first

- Exactly-once continuation completion under reply/error/interruption/invalidation
  races.
- App/native-host role/capability matrix.
- Warm call, reconnect, and teardown latency.
- Connection reuse and leak soak.
- Native-host recovery after interruption and agent replacement.
- TSan, Main Thread Checker, and anonymous-listener tests.

#### Acceptance

- Session invariants exist in one implementation.
- App and native host have consistent reconnect/failure semantics where their
  roles allow.
- Neither adapter can claim a role or capability not validated by the server.
- Connection reuse, teardown, continuation, latency, and leak targets pass.
- Deleting the session module would spread real complexity into both adapters.

#### Rollback

No protocol or schema migration. App and native-host adapter migrations land as
separately revertible slices; both must pass before the old duplicated session
implementation is deleted.

### P8 — Full verification, comparison, and handoff

#### Objective

Prove that the architecture changes improved final outcomes rather than only
proxy diagnostics.

#### Required validation

```bash
make doctor
make verify-fast
make test-integration
make test-recovery
make test-performance
make analyze
make test-asan
make test-tsan
make test-fuzz
make audit-dependencies
make performance-compare BASELINE=Artifacts/baselines/<approved-before>.json
make verify
```

Interactive UI/accessibility validation remains a separate required lane where
the environment supports it. No signing/notarization action is part of this plan.

#### Acceptance

- Every requirement row links to raw current-build evidence.
- All performance-contract rows pass or the outcome is `INCOMPLETE`.
- No metric relies only on generated fixtures when an end-to-end path is
  required.
- No S1–S3 defect, sanitizer report, confirmed leak, sequence loss, or state
  invariant failure exists.
- The handoff follows `07-handoff-protocol.md` and begins with the correct outcome.

## 8. Testing strategy

### 8.1 Test distribution

- Domain/Application: deterministic rule and state tests.
- Persistence: in-memory GRDB adapter, SQL statement counter, query-plan checks,
  migration/index verification.
- Engine: controllable clock, bounded replay, progress pressure, Scheduler
  fairness, recovery races.
- XPC: anonymous-listener adapter, secure coding, sequence/reconnect/idempotency
  matrices.
- Presentation: read-model diffing, selection, terminal notification, main-actor
  performance.
- Integration: loopback transfer fixtures, real GRDB, XPC, agent/client lifecycle.
- Non-functional: XCTest metrics, signposts, Instruments Allocations/Leaks/Time
  Profiler/File Activity, wakeup and RSS sampling.

### 8.2 Test replacement rule

After a deep module passes parity:

1. Move observable behavior tests to the module interface.
2. Retain only internal tests required for unsafe adapter mechanics.
3. Delete tests whose only purpose was to access a shallow implementation.
4. Prove coverage and failure-matrix parity before deletion.

### 8.3 Required falsification tests

- A deliberately N+1 projection must fail the SQL-count test.
- A unique-ID polling loop must not cause replay storage growth past its bound.
- A dropped sequence must force a full refresh.
- A slow progress consumer must not create unbounded pending tasks.
- A lost Scheduler event must be recovered by the documented safety mechanism or
  fail the phase.
- A noisy or incompatible baseline must not produce a pass.
- A >10% seeded regression must fail `performance-compare`.

## 9. Security, privacy, and correctness gates

- Peer identity validation remains before request execution.
- No URL query, headers, cookie, credential, full path, or signing identity enters
  metrics/logs.
- XPC payload and collection caps remain enforced.
- Replay eviction cannot permit duplicate mutation execution silently; post-
  eviction behavior must be explicit and tested.
- Snapshot changes preserve stable wire values and never use localized strings as
  identifiers.
- Persistence indexes/migrations have backup/recovery proof where applicable.
- No test points at a real Downloads directory or user database.
- All added tasks have a documented lifetime owner; no detached task is accepted
  merely to make isolation warnings disappear.
- No gate, lint rule, warning policy, test, or failure assertion may be weakened.

## 10. Risk register

| Risk | Severity | Falsification/mitigation | Owner | Release effect |
|---|---|---|---|---|
| Replay eviction permits duplicate mutation | S2 | concurrent/expired duplicate matrix; explicit safe policy | Engine/XPC | Blocks P1 |
| Set-based projection changes ordering/data | S2 | golden parity + 10k randomized fixtures | Persistence | Blocks P2 |
| Snapshot change is lost or reordered | S2 | sequence gap/reconnect/restart matrix | Engine/XPC | Blocks P3 |
| N/N-1 app/agent mismatch | S2 | capability/fallback matrix | XPC | Blocks P3/P6 |
| Main-actor diff still hitches | S3 | hitch metric + 1%/100% change cases | Presentation | Blocks P3 |
| Progress coalescing loses terminal bytes | S2 | exact terminal and late-sample tests | Transfer | Blocks P4 |
| Progress path creates task backlog | S3 | slow-consumer million-sample test | Transfer | Blocks P4 |
| Event-driven Scheduler misses work | S2 | event-loss, safety-wake, recovery tests | Engine | Blocks P5 |
| Schedule behavior fails across DST/sleep | S3 | injected clock/calendar matrix | Engine | Blocks P5 |
| Measurement noise hides regression | S3 | CV limit, same-machine metadata, rerun | Performance | Blocks decision |
| Refactor makes shallow modules | S4 | deletion test + interface review | Reviewer | Reject candidate |
| Security rules drift during XPC cleanup | S2 | ADR checklist + fail-closed tests | Security/XPC | Blocks P1/P6 |

## 11. Rollback and archive rules

- Every phase is a separate, behavior-complete, revertible slice.
- Additive indexes precede no destructive persistence change.
- The full Library refresh remains a genuine gap-recovery/N-1 path.
- A phase that misses an NFR target is reverted or remains unmerged; thresholds
  are not relaxed in implementation.
- A candidate is archived when:
  - baseline evidence disproves the claimed cost;
  - the deletion test shows no concentrated complexity;
  - it requires an ADR contradiction without measured benefit;
  - two justified adapters do not exist for a proposed external seam;
  - its maintenance cost exceeds its measured benefit.
- Archived candidates record evidence and the condition that would justify
  reopening them.
- No destructive cleanup of user files, databases, backups, baselines, or result
  bundles occurs without immediate explicit authorization.

## 12. Explicit non-goals

- No product-code implementation in this planning task.
- No concrete new interface/type design before candidate grilling.
- No media helper, libtorrent/magnet, notarization, release, or VoiceOver work.
- No UI visual redesign.
- No direct Presentation access to GRDB.
- No replacement of libcurl, GRDB, XPC, AppKit table, or the LaunchAgent model.
- No broad split of `TransferOrchestrator.runJob` merely to reduce line count; its
  external interface is already deep. Reassess internal locality only after P2–P7.
- No code generation for XPC contracts without a separate design-it-twice review.
- No commit, push, fetch, pull, PR, issue, release, or signing action.

## 13. Required artifacts per phase

```text
Artifacts/validation/architecture-performance/<phase>/<UTC>/
  environment.json
  git-status.txt
  build.log
  unit-tests.xcresult
  integration-tests.xcresult
  recovery-tests.xcresult
  performance.xcresult
  performance.json
  performance-comparison.json
  query-plans/
  instruments/
  sanitizer-asan.log
  sanitizer-tsan.log
  static-analysis.log
  banned-token-scan.txt
  traceability.md
  summary.md

Artifacts/handoffs/architecture-performance-<phase>-<UTC>.md
```

Each summary states the exact commit, dirty state, commands, exit codes, artifact
paths, before/after/threshold values, unsupported manual lanes, known issues, and
next authorized action.

## 14. Definition of done

This plan is implementation-complete only when:

1. P0–P8 acceptance criteria pass on the exact final bits.
2. The Library path has constant-statement persistence projection and
   change-aware delivery.
3. XPC replay storage and app/agent RSS reach documented plateaus.
4. Progress and Scheduler pending work remain bounded under stress.
5. Same-machine final outcomes meet every performance-contract target.
6. All repository validation, security, sanitizer, recovery, and documentation
   gates pass.
7. Independent review confirms no shallow pass-through module, duplicate policy,
   stale path, or test that reaches past an interface.
8. The handoff is `COMPLETE` with raw evidence; otherwise it is `INCOMPLETE` or
   `BLOCKED` according to the normative handoff protocol.

## 15. Open decisions before implementation

1. Confirm or reorder the candidate priority after reviewing the visual report.
2. Run the grilling/design-it-twice step for the selected deep module.
3. Approve the exact interface and compatibility strategy.
4. Approve the current-main baseline artifact after P0 capture.
5. Authorize one phase only; approval does not carry to later phases or remote
   actions.

## Debate Round 1

### Reviewer Objections

| ID | Section | Issue | Why It Matters | Requested Change | Test |
|---|---|---|---|---|---|
| R1-01 | Performance contract | Absolute budgets had no provenance or ratification rule. | An arbitrary budget can be relaxed after seeing poor current results and still appear objective. | Label normative versus provisional targets and constrain DG-1 changes. | Every target has provenance; loosening requires recorded rationale and approval. |
| R1-02 | Performance contract | `p95`, CPU, RSS slope, wakeups, main-actor time, and payload size lacked exact measurement definitions. | Two implementers could produce incomparable “passing” evidence. | Define sample count, warmup, formulas, corroborating tools, and non-comparable outcome. | Two independent runs produce the same metric schema and satisfy CV ≤ 5%. |
| R1-03 | P0/P8 | Proxy diagnostics and final results were both listed without an explicit verdict rule. | Optimizing fixture/table proxies could leave the persistence/XPC path slow. | State that proxies diagnose only; end-to-end scenarios decide acceptance. | A fast proxy plus failing end-to-end scenario must fail P0/P8. |
| R1-04 | P0 | Baseline capture, approval, and overwrite protection had no explicit owner split. | A new implementation could overwrite its own comparison input. | Separate candidate capture from approved-baseline promotion and require immutable hashes/reproduction. | Capture cannot write the approved path; promotion requires a second comparable run. |

### Planner Responses

| ID | Outcome | Response | Plan Change |
|---|---|---|---|
| R1-01 | accepted_plan_revision | The normative 10% rule is now distinct from provisional product budgets. | Added threshold provenance and DG-1 ratification constraints. |
| R1-02 | accepted_plan_revision | Each gating metric now has a reproducible measurement definition. | Added post-warmup sample count, formulas, tool corroboration, and `NOT COMPARABLE`. |
| R1-03 | accepted_plan_revision | Proxy measurements no longer qualify as final proof. | Added an explicit proxy-versus-end-to-end verdict rule in §5 and P0. |
| R1-04 | accepted_plan_revision | Baseline promotion is now an approval action separate from capture. | Added immutable candidate hash, rerun, owner/approver table, and overwrite prohibition. |

### Plan Changes

- Added threshold provenance and immutable approval rules.
- Added metric calculation and comparability definitions.
- Added explicit proxy/final-result separation.
- Added decision ownership.

### Open Blockers

- DG-1 current-main baseline has not been captured; this is intentionally a P0
  implementation prerequisite.
- No implementation phase is authorized.

### Stop/Continue Decision

Continue — measurement objections are resolved at plan level; security and
compatibility assumptions still require challenge.

## Debate Round 2

### Reviewer Objections

| ID | Section | Issue | Why It Matters | Requested Change | Test |
|---|---|---|---|---|---|
| R2-01 | P1 | Bounded replay eviction conflicts with exactly-once behavior for non-naturally-idempotent mutations such as enqueue. | Evicting a receipt can allow duplicate durable jobs after retry/reconnect. | Define guarantee horizon, classify commands, compare bounded-session and durable-ledger designs, and fail closed outside the chosen guarantee. | Duplicate enqueue before/after eviction, reconnect, client crash, and agent restart creates one durable batch/job set. |
| R2-02 | P1 rollback | “No schema migration” prematurely excluded a safe durable idempotency design. | The rollback rule could force an unsafe in-memory compromise. | Permit an additive backward-compatible ledger only if evidence selects it; define downgrade/pruning proof. | Migration/backup/restore/downgrade and crash-between-mutation-and-receipt tests pass. |
| R2-03 | P3 | N/N-1 compatibility was named but not enumerated. | App update and an older running agent can produce selector/version/sequence failures. | Enumerate supported pairings, agent replacement, unknown capability, and typed outcomes. | Every matrix row yields change-aware delivery, full-refresh fallback, or typed upgrade-required rejection. |

### Planner Responses

| ID | Outcome | Response | Plan Change |
|---|---|---|---|
| R2-01 | accepted_plan_revision | Replay semantics are now a security decision, not a cache-size detail. | Added command classification, guarantee horizon, two-design comparison, fail-closed behavior, and durable enqueue proof. |
| R2-02 | accepted_plan_revision | The plan no longer assumes the safe solution is schema-free. | Replaced rollback text with additive migration/downgrade requirements and a `BLOCKED` stop rule. |
| R2-03 | accepted_plan_revision | Compatibility now has explicit rows and permitted outcomes. | Expanded P3 tests/acceptance and documented the recovery-path removal condition. |

### Plan Changes

- Made mutation replay safety a prerequisite to bounded eviction.
- Allowed only evidence-backed additive persistence for idempotency.
- Expanded compatibility and rollback matrices.

### Open Blockers

- Exact replay storage and guarantee horizon require the selected-candidate
  grilling/design step.
- Signed cross-process validation remains a future release-environment lane; it
  cannot be claimed by anonymous-listener tests.

### Stop/Continue Decision

Continue — replay and compatibility are now safely gated; phase independence and
interface-prematurity remain to be challenged.

## Debate Round 3

### Reviewer Objections

| ID | Section | Issue | Why It Matters | Requested Change | Test |
|---|---|---|---|---|---|
| R3-01 | Former P6 | Server request locality and client-session locality were combined despite different seams, adapters, and rollback risks. | One failure could block or obscure the other and violate independent phase delivery. | Split them into separate phases with separate tests/rollback. | Each phase can be implemented, verified, and reverted without changing the other. |
| R3-02 | Whole plan | The architecture skill forbids concrete interface design before candidate selection/grilling. | Premature methods/types would anchor the wrong seam. | Remove interface designs or prove the document contains constraints only. | No method/type signature or final parameter/error surface is prescribed; DG-0 and grilling remain mandatory. |
| R3-03 | Decision gates | Phase and threshold ownership was too generic. | Implementer self-approval weakens independent evidence. | Add responsible/approver roles and independence rule. | Every gate names an approver and required artifact; implementer is not the independent Reviewer. |
| R3-04 | Metadata | The visual report path is temporary. | A durable plan must remain understandable after OS temp cleanup. | Mark the visual as session-local and keep all decisions/evidence in the plan. | Removing the HTML file leaves the plan complete and executable. |

### Planner Responses

| ID | Outcome | Response | Plan Change |
|---|---|---|---|
| R3-01 | accepted_plan_revision | The two deep modules now have independent ownership, proof, and rollback. | Split server request locality into P6, client session into P7, and moved final proof to P8. |
| R3-02 | artifact_backed_rebuttal | The plan explicitly says it is not an interface-design document, DG-0 requires candidate choice, and open decisions require grilling/design-it-twice before approval. It specifies behavior and falsification tests only. | No interface removal required; retained the explicit prohibition and non-goals. |
| R3-03 | accepted_plan_revision | Independent decision ownership is now explicit. | Added §6.1 responsible/approver/evidence table and Reviewer independence rule. |
| R3-04 | accepted_plan_revision | The temporary report is discovery evidence, not a dependency. | Added a metadata note declaring this plan self-contained. |

### Plan Changes

- Split P6/P7 and renumbered final verification to P8.
- Added decision ownership and review independence.
- Clarified temporary-versus-durable artifact roles.
- Reconfirmed that exact interfaces remain unresolved until grilling.

### Open Blockers

- Maintainer candidate selection remains open; the top recommendation is only the
  default order.
- P0 baseline capture and every implementation phase require separate future
  authorization.

### Stop/Continue Decision

Stop — all critical plan-level objections are resolved. The plan remains
`PROPOSED`, not authorized for implementation.
