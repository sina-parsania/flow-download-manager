# Governance

How **Download Manager** is maintained, how decisions are made, and how releases
are authorized. This document is normative repository policy. It describes the
governing model and process, not delivered user features: the project is at
**Phase 0 — repository foundation**, and no user-facing download capability has
shipped yet.

It complements, and does not override, the operating contracts already in the
repository: [`AGENTS.md`](AGENTS.md), the master plan and release train
([`macos-download-manager-prompt-pack/00-master-plan.md`](macos-download-manager-prompt-pack/00-master-plan.md)),
the quality/testing/release gates
([`macos-download-manager-prompt-pack/05-quality-testing-release-gates.md`](macos-download-manager-prompt-pack/05-quality-testing-release-gates.md)),
and the licensing/security/privacy policy
([`macos-download-manager-prompt-pack/06-licensing-security-privacy.md`](macos-download-manager-prompt-pack/06-licensing-security-privacy.md)).
Where any of those conflict with this file on their own subject matter, they win.

The project is licensed **GPL-3.0-or-later**. Contributions are accepted under
that license.

## 1. Roles

This is a **maintainer-led** project. There is no board, no foundation, and no
legal entity implied by this document.

- **Contributors** — anyone who opens an issue or a pull request. Contributors
  do not need commit rights to participate; the normal path to change is a pull
  request.
- **Maintainers** — people with review and merge authority. Maintainers are
  responsible for code quality, architecture-boundary enforcement
  (`AGENTS.md` §"Architecture boundaries"), scope discipline (no future-phase
  surface area lands early), and for keeping `main` releasable.
- **Release owner** — a single designated maintainer who owns the release train.
  The release owner accepts or rejects S4 defects for a release
  (`05` §12, `00` §7/§8), owns the security-incident and key-compromise response
  (`06` §11, §4), and is one of the two required approvers for any signed,
  notarized, or published build (see §4). The role may be delegated for a given
  release, but the delegation is explicit and recorded, and the delegate then
  carries the same authority and the same restrictions.
- **Dependency / CVE review owner** — a maintainer role that owns the shipped
  dependency manifest and its vulnerability review (`06` §2, §11). Each
  shipped dependency additionally has a named component owner and a
  last-review date in the manifest; the review owner ensures those entries stay
  current and that CVE, license, and notarization gates are re-run on every
  upgrade.

The current holders of the release owner and dependency/CVE review roles are
recorded as part of the Phase 5 documentation set (`06` §1). Until that set is
published, treat the role holder as
**`<release-owner configured by the project>`** and set it before any public
release. This document uses roles, not personal names, so it does not go stale
when people rotate.

## 2. How decisions are made

**Lazy consensus on pull requests.** Most changes are decided by lazy consensus:
a pull request that has at least one maintainer approval, no unresolved
maintainer objection, and green required checks may be merged. Silence is
assent; a change does not need every maintainer to weigh in.

**Maintainer review is required.** No change reaches `main` without at least one
maintainer's explicit approval. Changes that touch an architecture boundary
(the one-directional layer imports in `AGENTS.md`), the XPC or persistence
contracts, the security controls in `06`, or the build/gate configuration
require review from a maintainer familiar with that area. `main` must always
pass the stable gate and remain releasable (`00` §5).

**Objections and escalation.** A maintainer may block a pull request by leaving
an explicit, substantive objection; a blocking objection must be actionable, not
a bare veto. The escalation path when contributors and reviewers cannot reach
agreement:

1. Discuss on the pull request or issue and try to resolve on the technical
   merits, referencing the relevant repository policy.
2. If unresolved, the maintainers discuss and seek consensus among themselves.
3. If still unresolved, the **release owner decides** and records the rationale.
   The release owner's decision is the tie-breaker, and is bounded by the
   normative documents above — it cannot waive an S1–S3 blocker or relax a gate.

Amendments to this document follow the same pull-request path and additionally
require agreement from a majority of maintainers, including the release owner.

## 3. Change control

- `main` is protected: changes land only through reviewed pull requests, never
  by direct push.
- Required checks must pass before merge. The stable gate is the `make`
  interface (`make verify-fast` for the fast lane, `make verify` for the full
  gate and evidence bundle; see `AGENTS.md` §"Build & test commands" and
  `08-validation-commands.md`). Gates are never weakened to make a change pass
  (`AGENTS.md` §"Strict gates").
- Continuous integration policy: PR CI runs the stable gates and **must run
  without any signing, notarization, or publishing credential**. No production
  secret is available to CI on pull requests (`AGENTS.md`
  §"Remote-action approval policy", `06` §4). CI as a running pipeline is itself
  Phase 0 foundation work; this section is the policy it must satisfy, stated in
  normative voice.
- Remote actions that mutate shared state — pushing, tagging, creating GitHub
  releases/issues/PRs, publishing the extension, signing/notarizing with
  protected credentials, uploading an appcast — require explicit human
  authorization immediately before the action, per `AGENTS.md`. Authorization
  for one action never authorizes the next.

## 4. Release process and two-person approval

The project ships a phased release train, Phases 0 through 5 (`00` §3). The
governance rules differ between an internal phase completion and a build that is
actually signed, notarized, and published to users.

**Phase completion (internal).** A phase is complete only when its phase exit
gate is green (`00` §7): every in-scope requirement has automated verification
and a traceability entry; all affected unit, integration, UI, performance,
recovery, sanitizer, and fuzz suites pass; zero first-party warnings; the
accessibility checks pass; documentation matches actual behavior with no
future UI exposed; the threat model and dependency manifest reflect the new
attack surface; and known S1–S3 defects are zero, with S4 issues explicitly
accepted by the release owner. Evidence is captured under
`Artifacts/validation/<phase>/<timestamp>/` (`05` §13) and referenced in the
handoff (`07-handoff-protocol.md`).

**Signed / notarized / published builds require two-person approval.** The
Developer ID signing, Hardened Runtime, notarization, stapled DMG, and Sparkle 2
appcast machinery are Phase 5 deliverables (`00` §3, `06` §5). Producing a
build that is signed, notarized, or published to users requires, in addition to
the applicable phase exit gate:

- **Two distinct humans** to approve the signing/notarization/publishing action.
  The release owner is one authorized approver but **cannot supply both
  approvals**; a second maintainer must independently approve. This is the
  concrete form of the "explicit human authorization immediately before"
  requirement in `AGENTS.md` and the two-person release approval in `06` §4.
- The **release-artifact gate** on the exact bits being shipped (`05` §11):
  signature verification for the app, agent, native host, and every bundled
  executable/framework; entitlement/Hardened Runtime audit; notarization
  accepted and ticket stapled; Gatekeeper assessment; DMG structure and
  signature; Sparkle appcast signature and update from N-1; no debug
  symbols/secrets/test certificates/private keys in the artifact; SBOM, source
  offer, and third-party-notice correspondence; and CVE policy.

**Protected credentials live only in the release environment.** Private EdDSA
update keys and the Developer ID signing identity exist **only in a protected,
human-triggered release environment**, never in CI on pull requests and never in
the general development flow (`06` §4, `00` §6). Ordinary development and PR
validation neither need nor receive release credentials. Nothing on a pull
request path can sign, notarize, or publish.

**Phase gates that must pass before a release.** Before a build is released, the
four gate families the release train enforces must be green on the release
candidate:

- **Build/test** — clean build with warnings as errors and the full test
  suites (`05` §6, and the phase exit gate in `00` §7).
- **Sanitizer** — ASan and TSan (run separately, never combined), Main Thread
  Checker, and the C/C++ UBSan/static-analyzer runs, each with zero reports
  (`05` §8).
- **Accessibility** — automated audit plus manual VoiceOver and keyboard-only
  scripts across the supported macOS families, with no unlabeled actionable
  element, focus trap, clipped critical text, or color-only state (`05` §9).
- **Security** — the threat-model, dependency/CVE, license, and
  release-artifact checks (`05` §11, `06` §11–§12), with zero unresolved
  S1–S3 finding.

If a required certificate, secret, physical runner, or external account is
unavailable, the release is reported `BLOCKED` with exact evidence; successful
external verification is never fabricated (`00` §2).

## 5. Security response and dependency review

**Security-incident response is owned by the release owner** (`06` §11, §4). The
release owner maintains the key-compromise and malicious-update response
runbook and coordinates the private handling of reports, embargo, fix, and any
expedited signed update. Critical or high remotely exploitable findings block
release and trigger an expedited, signed update through the normal signing path
(so the two-person approval of §4 still applies). Security fixes ship with
regression tests and follow the advisory/credit policy. The private reporting
channel and supported-version policy are published in `SECURITY.md` as part of
the Phase 5 documentation set; until then the reporting address is
**`<security-contact configured by the release owner>`** and must be set before
public release.

**Dependency and CVE review is owned by the dependency/CVE review owner**
(`06` §2, §11). A dependency vulnerability scan runs at least weekly and on
every dependency update and every release. Pinning does not excuse a stale,
vulnerable dependency: any upgrade re-runs the compatibility, checksum, license,
CVE, and notarization gates and updates the manifest's last-review date. No
binary enters the app bundle without a corresponding source/build manifest and
license approval.

## 6. Becoming a maintainer

Maintainership is earned through sustained, high-quality contribution, not
requested. The path:

1. A track record of merged pull requests, reviews, or issue triage that shows
   good judgment, respect for the architecture boundaries and strict gates, and
   discipline about phase scope.
2. Nomination by an existing maintainer.
3. Agreement by lazy consensus among the maintainers — approval from the other
   maintainers with no sustained, substantive objection, and confirmation from
   the release owner.

A new maintainer receives review and merge rights and is added to the
role-based maintainer list in the Phase 5 documentation set. Maintainers are
expected to disclose conflicts of interest and to recuse themselves where
appropriate. A maintainer may step down at any time and be listed as emeritus;
maintainers who are inactive for an extended period, or who repeatedly act
against the project's policies, may be moved to emeritus by consensus of the
remaining maintainers and the release owner. Emeritus status removes merge
rights and can be reversed by the same process that grants maintainership.

---

Placeholders in this document (**`<release-owner configured by the project>`**,
**`<security-contact configured by the release owner>`**) are deliberate: they
must be replaced with real values by the release owner before any public
release. This file will not invent an organization, domain, email address, or
legal entity in their place.
