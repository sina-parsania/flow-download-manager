# ADR 0003 — XPC client identity via audit token + code-signing requirement

Status: accepted (Phase 0)

## Context

The engine agent must authorize XPC peers using **process identity, not a
caller-supplied role** (`04-domain-and-data-contracts.md` §9), verified by
"audit token/code-signing requirement" (`02-architecture.md` §10,
`06-licensing-security-privacy.md` §4). `NSXPCConnection.processIdentifier` is
subject to PID reuse and is unsafe for authorization. The race-free mechanism is
the connection's **audit token** fed to `SecCodeCopyGuestWithAttributes`, then
`SecCodeCheckValidity` against a `SecRequirement`.

`NSXPCConnection.auditToken` is declared by Foundation but is **not surfaced in
the generated Swift interface** (only `processIdentifier` and
`effectiveUserIdentifier` are). This project is direct Developer ID distribution
(not Mac App Store), where reading that property is the accepted, Quinn
"The Eskimo!"-documented technique.

## Decision

- A single, minimal Objective-C shim target `XPCSecuritySupport` re-declares
  `-auditToken` in one file and exposes `auditToken(for:)` to Swift. All contact
  with the SPI is contained and reviewable there.
- `CodeSigningIdentityValidator` derives a `SecCode` from the audit token and
  calls `SecCodeCheckValidity(code, [], requirement)`. The requirement is
  injectable; the default requires the peer's code-signing **identifier** to be an
  allowlisted value (`XPCClientIdentities`), which holds even under local ad-hoc
  signing. The release owner supplies a stronger requirement (adding
  `anchor apple generic` + team identifier) in the signed environment.
- The listener **fails closed**: any peer failing validation is rejected in
  `shouldAcceptNewConnection`. A `SameProcessIdentityValidator` exists for the
  in-process anonymous-listener tests only and never ships.

## Consequences

- Authorization is race-free and does not trust caller-provided data.
- The SPI dependency is one small ObjC file; if Apple surfaces `auditToken` in
  Swift, the shim can be deleted and this ADR superseded.
- Full cross-process acceptance (a real signed app connecting to a real signed
  agent) is validated in the integration suite / on a signed build; the rejection
  path and the in-process round-trip are validated in unit tests.
