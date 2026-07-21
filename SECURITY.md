# Security Policy

Download Manager is a native macOS application (macOS 14.0+, Apple Silicon /
arm64 only) distributed as a code-signed, notarized Developer ID build outside
the Mac App Store. It runs as a main app plus a per-user `DownloadEngineAgent`
LaunchAgent that communicate over an authenticated, versioned XPC interface.

The project is currently at **Phase 0 — repository foundation**. There are no
shipping user download features yet; this policy governs the security of the
codebase, its architecture, and the release pipeline as they are built.

We take security seriously and appreciate coordinated, good-faith reports.

## Reporting a Vulnerability

**Please do not open a public GitHub issue, pull request, discussion, or any
other public thread for a suspected vulnerability.** Public disclosure before a
fix is available puts users at risk.

Report privately through one of the following channels:

1. **GitHub private security advisories (preferred).** Use the repository's
   **Security → Advisories → Report a vulnerability** page to open a private
   advisory. This keeps the report, discussion, and any fix coordination in one
   place, visible only to you and the maintainers until disclosure.

2. **Direct security contact.** If you cannot use GitHub advisories, contact the
   release owner at `<security-contact configured by the release owner>`.

> This placeholder **must be replaced with a real, monitored channel before the
> first public release.** Do not treat the placeholder as a live address.

When reporting, please include as much of the following as you can:

- A clear description of the issue and its security impact.
- The affected component (app, `DownloadEngineAgent`, XPC interface, native
  messaging host, build/release tooling) and version or commit.
- Step-by-step reproduction, proof-of-concept, or a crashing input.
- Your assessment of severity and any known mitigations.

Please give us a reasonable opportunity to investigate and remediate before any
public disclosure.

## Supported Versions

Because the project is pre-1.0, **only the latest released version is
supported** for security fixes. Older releases and pre-release builds do not
receive backported patches — please reproduce and report against the most recent
release. Support policy for maintained release lines will be revisited at 1.0.

| Version         | Supported          |
| --------------- | ------------------ |
| Latest release  | :white_check_mark: |
| Any older build | :x:                |

## Coordinated Disclosure and Response Targets

We follow coordinated disclosure. Our targets, on a best-effort basis:

- **Acknowledge** a valid report within a few business days of receipt.
- **Triage** — confirm or dismiss, and assign a severity — shortly after
  acknowledgement.
- Keep you informed of remediation progress and coordinate a disclosure timeline
  and any credit you would like.

These are targets, not contractual guarantees, and may vary with report
complexity and volume. We ask that reporters keep details private until a fix
has shipped and the coordinated disclosure date has passed.

## Scope

### In scope

- The main **Download Manager** application.
- The per-user **`DownloadEngineAgent`** LaunchAgent.
- The **XPC interface** between the app and the agent (authentication, peer
  code-signing validation, message/version handling, DTO decoding).
- The **native messaging host** used to bridge the companion browser extension.
- The **dependency supply chain**: third-party packages, pinned tool versions,
  and the code-signing / notarization / update-distribution pipeline.

### Out of scope

- Issues that require a jailbroken, rooted, or otherwise compromised operating
  system, or that assume an attacker who already has root/administrator control
  of the machine.
- Social engineering of maintainers or users (phishing, pretexting, physical
  access attacks, and similar).
- Findings that depend on unsupported OS versions, non-Apple-Silicon hardware, or
  builds modified outside the official signed distribution.
- Best-practice or hardening suggestions with no demonstrable security impact.

If you are unsure whether something is in scope, report it privately and let us
assess.

## Release Impact of Security Findings

A confirmed **critical or high-severity, remotely exploitable** finding is a
**release blocker**: it stops the affected release and triggers an **expedited,
code-signed and notarized update** through the normal Developer ID distribution
channel once a fix is validated. Lower-severity issues are scheduled into regular
releases.

## Privacy and Telemetry

Download Manager performs its processing **locally** and ships **no telemetry**:
no analytics, no usage or crash reporting uploaded by default, and no background
network reporting. There is no account system. This is a deliberate design
constraint — reports of any undisclosed data collection or exfiltration are
firmly in scope.

## No Bug Bounty

This project does **not** offer a paid bug-bounty or any monetary reward. We
gratefully acknowledge reporters (with your permission) in the relevant security
advisory. Please report because you want users to be safe, not for payment.
