# COMPLETE — range-probe hardening (fragile signed URLs + 1-byte cap)

UTC: 20260725T2115Z

## Changes

- `RangeProbePolicy`: skip probe for Cookie headers and fragile signed query
  shapes; exempt AWS / GCS / Azure SAS so multi-segment stays fast
- Probe body capped at 1 byte in C (`bodyByteLimit`) — no-range hosts cannot
  turn the probe into a full download
- Probe `httpStatus` fallback → single GET (fresh + empty-map resume)
- Native Messaging allowlist adds `Authorization`
- Fault fixtures: `once`, `range-forbidden`, `no-range-large`; query stripped
  from fixture routing

## Evidence

- `make verify-fast`: OK (391 unit)
- `make test-integration`: OK (37)
- `make test-recovery`: OK (3)
- `make test-asan`: OK
- Speed check: `testAWSSignedQueryStillSegments` → segmentCount == 2

## Not done

- `make test-tsan` / full `make verify`
- Extension still does not fabricate Authorization (only forwards if present)
