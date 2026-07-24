---
paths:
  - "Sources/XPCContracts/**"
  - "Sources/EngineAgent/EngineService.swift"
  - "Sources/Presentation/EngineClient.swift"
  - "Sources/Persistence/**"
---

# XPC boundary and the sole-writer rule

## The process rule

The UI never owns sockets, partial files, checkpoints, or the queue. Only `DownloadEngineAgent` writes the database or moves a job into an active transfer state. If a change makes `Presentation` touch any of those, it is the wrong change — add an RPC instead.

## Adding or changing an RPC touches four files, always

1. `XPCContracts/EngineControlProtocol.swift` — the method
2. `XPCContracts/EngineControlInterface.swift` — the `NSXPCInterface` class allowlist for the DTOs
3. `EngineAgent/EngineService.swift` — the implementation
4. `Presentation/EngineClient.swift` — the caller, **plus the `capabilities` array in `ClientHello`**

Forgetting the interface registration fails at runtime, not compile time, with an opaque decoding error. Forgetting the capability string breaks the handshake gate.

## DTOs

`NSSecureCoding`, and every nested class must be declared in the interface allowlist. Round-trip coverage lives in `Tests/Unit/XPCCodingTests.swift` — add to it when you add a DTO.

## Idempotency and the replay store

Duplicate `requestID` must replay the prior response rather than re-execute. `RequestReplayStore` bounds this by count / age / bytes, and separately remembers executed **mutation** IDs so an evicted response fails closed instead of silently re-running the mutation.

Two things to keep true:

- **Never size an entry by archiving it.** An earlier revision called `NSKeyedArchiver.archivedData(requiringSecureCoding:)` inside the size estimator, so `listJobs` re-serialized the whole job list on every poll — in the process that also runs curl — behind a doc comment calling it "cheap". Use an O(1) per-element estimate.
- Reads may be recomputed on a miss; mutations may not.

## The read path is polled

`LibraryModel` polls `listJobs` (500 ms while a job is live, 5 s idle). Anything you add to that path runs at that rate, forever, on the agent process. Before adding work there, ask what it costs at 2 Hz with 500 rows of history.

`fetchJobRows` is a constant-statement plan (jobs + batched resources/categories/projects + one tag join), guarded by a statement-count test. Keep it constant — a per-row `fetchOne` reintroduces an N+1 that competes with live transfers for the same process.

## Transport

Two paths share one Mach name: the **bundled XPC service** (`Contents/XPCServices/DownloadEngineAgent.xpc`, ad-hoc/unsigned, the community default) and **SMAppService/LaunchAgent** (signed installs only).

On macOS 26+ `NSXPCListenerEndpoint` can only be encoded by `NSXPCCoder`, so the old "spawn a child, write an endpoint file, unarchive it" handshake cannot work. It has been removed. Don't reintroduce it.
