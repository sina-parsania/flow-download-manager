# HANDOFF — TASK 4 per-host settings complete

**COMPLETE** for HANDOFF.md TASK 1–4 and the review bugs carried with TASK 1–3.
**NOT STARTED (deliberately):** HANDOFF §5 items (torrent, media, notarization,
Safari extension, superseded straggler-preemption).

Written 2026-07-24T2150Z. Commits are local on `main` (ahead of origin). **Do not
push or release** until the human asks.

---

## Shipped

### TASK 4 — Per-host settings
- Schema **v5** `host_settings` (host PK, maxConnections, maxBytesPerSecond,
  userAgent, credentialProfileID, updatedAt)
- `HostSettingRepository` + normalizeHost
- XPC: `listHostSettings` / `upsertHostSetting` / `deleteHostSetting` (+ interface
  allowlist + ClientHello/ServerHello capabilities)
- `TransferOrchestrator` applies host overrides with precedence
  **per-job > per-host > global** for rate; job preferred connections else host
  maxConnections; host credential if job has none; host UA via header if unset
- Settings UI section “Per-host settings”
- Tests: repository, migration v4→v5, XPC coding, rate precedence

### Prior commits this session (already on main)
- resilient engine + hedge cancel + validator resume
- RTT/loss throughput curves
- performance-compare metric extraction
- handoff docs

---

## Gates (quoted)

| lane | result |
|---|---|
| `verify-fast` | **348** unit, 0 fail; incomplete-work-scan clean |
| `test-integration` | **30**, 0 |
| `test-recovery` | **3**, 0 |
| `test-performance` | **6**, 0 |
| `test-asan` | TEST SUCCEEDED · no ASan reports |
| `test-tsan` | TEST SUCCEEDED · no TSan reports |

SwiftLint still not installed (grep backstop only).

---

## Next (only if human asks)

1. Push / release / VERSION bump
2. `make performance-baseline` + promote approved baseline
3. Anything from HANDOFF §5 (explicitly deferred)
