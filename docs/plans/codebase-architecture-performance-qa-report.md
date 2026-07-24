# QA Report — Codebase Architecture and Performance Improvement Plan

- Result: `PASS — PLAN QUALITY`
- Implementation readiness: `GATED — DG-0/DG-1 NOT COMPLETE`
- Plan under test: `docs/plans/codebase-architecture-performance-improvement-plan.md`
- Baseline commit inspected: `ccdacdc`
- QA date: `2026-07-24`
- QA scope: documentation correctness, evidence traceability, architecture depth,
  performance measurability, security/compatibility, phase independence,
  rollback, debate conformance, and repository scope

## 1. Expected result

The plan must be implementation-focused and executable without implementing
product code. It must:

1. Ground architecture/performance claims in current repository evidence.
2. Use the deep-module vocabulary consistently.
3. Preserve normative architecture, security, validation, and handoff contracts.
4. Separate diagnostic proxies from final end-to-end results.
5. Define measurable targets, falsification tests, rollback, and stop rules.
6. Deliver independently reviewable phases with one future authorization at a
   time.
7. Complete an argue-plan loop with all critical objections resolved.
8. Avoid concrete interface design until candidate selection and grilling.
9. Avoid product implementation, remote actions, commits, and destructive work.

## 2. Observed result

The final plan satisfies all document-level acceptance criteria.

- Nine future phases are present: P0–P8.
- Fifteen unique requirement IDs map architecture, performance, reliability,
  security, compatibility, and documentation outcomes to proof.
- Three debate rounds contain Reviewer objections, allowed Planner outcomes,
  plan changes, open blockers, and stop/continue decisions.
- Eleven objections were resolved: ten `accepted_plan_revision`, one
  `artifact_backed_rebuttal`.
- The plan distinguishes normative regression policy from provisional product
  budgets and defines measurement formulas/comparability.
- The plan treats proxy diagnostics as non-decisive and requires end-to-end
  persistence → engine → XPC → Presentation evidence.
- XPC replay safety, non-idempotent enqueue behavior, eviction, reconnect, and
  restart are explicit security gates.
- Server request locality and client-session locality are separate phases.
- Exact interfaces remain open decisions behind DG-0 and grilling/design-it-twice.
- No product source/test/config file was edited.

## 3. QA matrix

| ID | Check | Method | Result | Evidence |
|---|---|---|---|---|
| QA-001 | Scope is documentation-only | Working-tree inspection | PASS | Only `docs/` was added by this task; pre-existing `Documentation/diagnosis-intake.md` remains untouched |
| QA-002 | Current baseline is identified | Metadata inspection | PASS | Plan records `main@ccdacdc` and current dirty-state exception |
| QA-003 | Claims use current evidence | Graph/history/artifact cross-check | PASS | 1 Hz Library poll, 27 unbounded response dictionaries, N+1 projection, 200 ms pump, per-sample progress task, missing comparator |
| QA-004 | Domain/architecture vocabulary is consistent | Manual review + vocabulary scan | PASS | Uses module, interface, implementation, depth/deep/shallow, seam, adapter, leverage, locality |
| QA-005 | YAGNI scope is explicit | Non-goal review | PASS | Defers media/torrent completion, UI redesign, libcurl/GRDB/XPC replacement, broad runJob split, and contract codegen |
| QA-006 | Phase set is complete and ordered | Heading extraction | PASS | P0 evidence → P1 safety → P2 projection → P3 delivery → P4 telemetry → P5 Scheduler → P6/P7 XPC locality → P8 proof |
| QA-007 | Phases are independently reversible | Phase/rollback review | PASS | P1–P7 have explicit rollback; P0 has stop rule; P8 is validation-only |
| QA-008 | Requirements are unique and traceable | ID extraction/count | PASS | 15 IDs, each unique in the traceability table |
| QA-009 | Performance targets are measurable | Metric-contract review | PASS | Scenarios, p95 definition, warmup, sample count, CV, CPU/RSS/payload formulas, final-result rule |
| QA-010 | Baseline cannot self-overwrite | P0 review | PASS | Candidate capture and approved promotion are separate; immutable hash and rerun required |
| QA-011 | Proxy diagnostics cannot pass final gate | P0/P8 review | PASS | End-to-end scenario explicitly controls verdict |
| QA-012 | XPC retention is bounded safely | P1 review | PASS | Count/age/byte limits plus guarantee horizon and non-idempotent mutation tests |
| QA-013 | Enqueue duplication is covered | P1 review | PASS | Before/after eviction, reconnect, client crash, and agent restart must yield one durable batch/job set |
| QA-014 | XPC peer security is preserved | ADR/plan review | PASS | ADR 0003 identity validation stays before request lifecycle |
| QA-015 | Native-host restrictions are preserved | ADR/plan review | PASS | ADR 0007 role/capability matrix remains required |
| QA-016 | N/N-1 compatibility is testable | P3 review | PASS | Pairings, agent replacement, unknown minor capability, fallback/rejection outcomes enumerated |
| QA-017 | Snapshot correctness is testable | P3 review | PASS | Ordered/duplicate/stale/gap/reconnect/restart/cancellation cases included |
| QA-018 | Progress work is bounded | P4 review | PASS | Million-sample slow-consumer test, 1/8/32 segments, publication/staleness/terminal exactness |
| QA-019 | Scheduler correctness precedes polling removal | P5 review | PASS | Clock/DST/sleep/fairness/race/query-plan tests and safety-wake falsification |
| QA-020 | Server/client XPC modules are separate | P6/P7 review | PASS | Different seams, tests, acceptance, and rollback |
| QA-021 | Debate format conforms | Structural extraction/manual review | PASS | All required round fields and allowed response outcomes present |
| QA-022 | Ownership prevents self-approval | Decision-owner review | PASS | Responsible/approver/evidence table and independent Reviewer rule |
| QA-023 | Handoff/evidence is executable | Artifact/command review | PASS | Per-phase evidence tree, stable make commands, performance compare, COMPLETE/INCOMPLETE/BLOCKED rules |
| QA-024 | Markdown hygiene | Pattern scan | PASS | No trailing whitespace or incomplete-work markers after correction |
| QA-025 | No remote/destructive claim | Plan and working-tree review | PASS | No commit, push, issue, PR, release, signing, upload, or deletion performed |

## 4. Resolved findings

### QAF-001 — Thresholds lacked provenance

- Severity: Major
- Initial behavior: absolute budgets appeared authoritative without identifying
  normative versus proposed values.
- Expected: explicit provenance and a controlled ratification rule.
- Resolution: Round 1 added normative/provisional classification, DG-1
  constraints, and approval requirements.
- Retest: PASS.

### QAF-002 — Measurement terms were open to interpretation

- Severity: Major
- Initial behavior: p95, CPU, RSS slope, wakeups, main-actor time, and payload
  size could be measured differently.
- Expected: reproducible formulas and a non-comparable state.
- Resolution: Round 1 added sample/warmup/CV rules and metric definitions.
- Retest: PASS.

### QAF-003 — Bounded replay conflicted with safe mutation idempotency

- Severity: Critical
- Initial behavior: eviction was required while post-eviction mutation safety was
  not fully designed, and P1 excluded schema changes.
- Expected: one documented guarantee horizon and no ambiguous re-execution.
- Resolution: Round 2 added command classification, bounded-session versus
  durable-ledger design comparison, enqueue durability proof, migration/downgrade
  tests, and a `BLOCKED` stop rule.
- Retest: PASS at plan level. Exact design intentionally remains open.

### QAF-004 — Compatibility matrix was too abstract

- Severity: Major
- Initial behavior: “N/N-1” was named without pairings/outcomes.
- Expected: explicit supported combinations and typed fallback/rejection.
- Resolution: Round 2 enumerated app/agent pairings, replacement, unknown
  capability, and recovery-path removal conditions.
- Retest: PASS.

### QAF-005 — One phase contained two deep modules

- Severity: Major
- Initial behavior: server request locality and app/native-host client-session
  locality shared former P6.
- Expected: independent implementation, proof, and rollback.
- Resolution: Round 3 split them into P6/P7 and moved final proof to P8.
- Retest: PASS.

### QAF-006 — Temporary visual path could appear durable

- Severity: Minor
- Initial behavior: plan metadata linked the OS-temp report without lifecycle
  clarification.
- Expected: durable plan remains self-contained.
- Resolution: Round 3 marked the HTML as session-local discovery evidence.
- Retest: PASS.

### QAF-007 — Metadata used trailing Markdown hard-break whitespace

- Severity: Cosmetic
- Initial behavior: hygiene scan reported intentional trailing spaces.
- Expected: zero trailing whitespace.
- Resolution: metadata became a list.
- Retest: PASS.

## 5. Open gates, not QA defects

| Gate | Status | Required next evidence |
|---|---|---|
| DG-0 candidate selection | OPEN | Maintainer selects/reorders candidate after visual review |
| Interface approval | OPEN | Grilling/design-it-twice record for selected module |
| DG-1 baseline | OPEN | P0 implementation, raw current-main samples, reproducibility rerun |
| Replay storage design | OPEN | Security-reviewed guarantee horizon and design decision |
| Implementation authorization | NOT GRANTED | Explicit approval for one phase only |
| Product validation | NOT RUN | Required only after product implementation changes |

These gates are intentionally open. They do not reduce the plan QA verdict
because the plan explicitly stops before implementation.

## 6. Verification commands

```bash
git status --short --branch
rg -n '^### P[0-8] — ' \
  docs/plans/codebase-architecture-performance-improvement-plan.md
rg -n '^## Debate Round [1-3]$|^### (Reviewer Objections|Planner Responses|Plan Changes|Open Blockers|Stop/Continue Decision)$' \
  docs/plans/codebase-architecture-performance-improvement-plan.md
rg -n '\| (accepted_plan_revision|artifact_backed_rebuttal|conceded_blocker|deferred_with_reason) \|' \
  docs/plans/codebase-architecture-performance-improvement-plan.md
rg -o '\b(ARCH|PERF|REL|SEC|COMP|DOC)-[0-9]{3}\b' \
  docs/plans/codebase-architecture-performance-improvement-plan.md | sort | uniq -c
```

Hygiene check:

```bash
if rg -n '[[:blank:]]+$|TODO|FIXME|HACK|PLACEHOLDER|NOT_IMPLEMENTED' \
  docs/plans/codebase-architecture-performance-improvement-plan.md
then
  exit 1
fi
```

Observed result: all structural/reference checks passed; hygiene check returned
no matches.

## 7. Product-test and GitHub disposition

- Product build/unit/integration/performance suites were not run because this
  task changed documentation only and the requested outcome was a plan plus its
  QA report.
- Existing handoff results were treated as historical evidence, not current test
  proof.
- No GitHub issue was created. The user authorized a written local QA report, not
  a remote mutation, and all plan-level findings were resolved locally.

## 8. Final verdict

`PASS — PLAN QUALITY`

The plan is evidence-backed, adversarially reviewed, measurable, reversible, and
safe to take into candidate selection/grilling. It is not authorization to
implement, and it must remain `PROPOSED` until DG-0, interface approval, DG-1,
and one-phase implementation authorization are complete.
