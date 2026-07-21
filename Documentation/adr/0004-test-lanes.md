# ADR 0004 — Test lanes via xcodebuild flags, not plan-internal target IDs

Status: accepted (Phase 0)

## Context

The spec asks for Standard, ASan and TSan test lanes
(`05-quality-testing-release-gates.md` §8, `08-validation-commands.md` §4). The
natural mechanism is `.xctestplan` files. However, an `.xctestplan` references its
test targets by their pbxproj **blueprint identifier**, and this project's
`.xcodeproj` is **generated** by XcodeGen (ADR 0001) — regeneration can change
those identifiers, so committed plan files silently drift out of sync and
`-testPlan` fails to resolve targets.

## Decision

- Test lanes are driven by the scheme's test target list plus **xcodebuild
  flags**, which are robust across regeneration:
  - Standard: `xcodebuild … test` (optionally `-only-testing:<Target>`).
  - ASan: `xcodebuild … -enableAddressSanitizer YES … test`.
  - TSan: `xcodebuild … -enableThreadSanitizer YES … test`.
  - Main Thread Checker: enabled by default in the scheme test action.
- ASan and TSan run in **separate passes** (they are not combined — §8).
- The Makefile targets (`test-asan`, `test-tsan`, `test-unit`, …) encode these
  flags, so the developer-facing interface in `08-validation-commands.md` is
  unchanged.
- UI automation (`UITests`) is excluded from the headless fast/stable gate and run
  on an interactive UI lane (it needs an automation-permitted session).

## Consequences

- Lanes survive `make project` regeneration with no manual identifier upkeep.
- If a future workflow needs shareable, Xcode-UI-visible test plans, they can be
  generated with correct identifiers as a build step; until then, flags are the
  source of truth.
